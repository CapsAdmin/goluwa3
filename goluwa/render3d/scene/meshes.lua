local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local store = import("goluwa/render3d/scene/store.lua")
local accel = import("goluwa/render3d/scene/accel.lua")
local index_pool = import("goluwa/render3d/index_pool.lua")
local meshes = {}
-- what the shaders read of a mesh. the bottom level structure of the mesh is built from its own vertex and index
-- buffers, instances only point at it, so any number of instances share one
local MeshRow = ffi.typeof([[struct {
	uint64_t vertex_address;
	uint64_t index_address;
	uint64_t blas_address;
	uint32_t triangle_count;
	uint32_t vertex_stride;
	uint32_t flags;
	uint32_t pool_first_index;
}]])
meshes.FLAG_INDEX_32 = 1
meshes.FLAG_HAS_INDICES = 2
meshes.TRIANGLES_PER_FRAME = 8 * 1024 * 1024
local table_rows
local by_mesh = setmetatable({}, {__mode = "k"})
local mesh_of_row = setmetatable({}, {__mode = "v"})
local records = {}
-- the meshes that deform, by the address of their vertices, for the structures to follow what skins them
local dynamic_records = {}
local pending = {}
local sweep_cursor = 0
local triangle_total = 0
local SWEEP_ROWS = 256

function meshes.GetTable()
	table_rows = table_rows or
		store.CreateTable{name = "meshes", ctype = MeshRow, capacity = 16384}
	return table_rows
end

-- the row of a mesh, which is built for ray tracing once and kept for as long as the mesh lives. nil for a mesh the gpu
-- has no buffers of
function meshes.Get(mesh, dynamic)
	local row = by_mesh[mesh]

	if row then return row end

	local vertex_buffer = mesh.vertex_buffer

	if not (vertex_buffer.buffer and mesh.mode == "triangle_list") then return nil end

	local index_buffer = mesh.index_buffer
	local triangle_count = index_buffer and
		math.floor(index_buffer:GetIndexCount() / 3) or
		math.floor(vertex_buffer:GetVertexCount() / 3)

	if triangle_count == 0 then return nil end

	local rows = meshes.GetTable()
	row = rows:Alloc()
	local data = rows:Get() + row
	data.vertex_address = vertex_buffer:GetBuffer():GetDeviceAddress()
	data.vertex_stride = vertex_buffer.stride
	data.triangle_count = triangle_count
	data.flags = 0

	if index_buffer then
		data.index_address = index_buffer:GetBuffer():GetDeviceAddress()
		data.flags = meshes.FLAG_HAS_INDICES + (
				index_buffer:GetIndexType() == "uint32" and
				meshes.FLAG_INDEX_32 or
				0
			)
	end

	by_mesh[mesh] = row
	mesh_of_row[row] = mesh
	local record = {
		row = row,
		vertex_address = tonumber(data.vertex_address),
		vertex_stride = data.vertex_stride,
		vertex_count = vertex_buffer:GetVertexCount(),
		index_address = tonumber(data.index_address),
		index_is_32 = index_buffer and index_buffer:GetIndexType() == "uint32",
		triangle_count = triangle_count,
		allow_update = dynamic,
		address = 0,
	}
	records[row] = record
	pending[#pending + 1] = record

	if dynamic then dynamic_records[record.vertex_address] = record end
	triangle_total = triangle_total + triangle_count
	return row
end

-- what drawing a mesh needs besides its buffers: indices in the shared index pool (a mesh without indices gets the
-- sequential ones, which is what its structure was built from as well), and the row says where they are
function meshes.EnsureRaster(row)
	local record = records[row]

	if record.raster_ready then return end

	local mesh = mesh_of_row[row]

	if not mesh.index_buffer then
		local vertex_count = mesh:GetVertexCount()
		local sequential = {}

		for i = 1, vertex_count do
			sequential[i] = i - 1
		end

		mesh:UploadIndices(sequential, vertex_count > 65535 and "uint32_t" or "uint16_t")
		local data = meshes.GetTable():Get() + row
		data.index_address = mesh:GetIndexBufferAddress()
		data.flags = meshes.FLAG_HAS_INDICES + (
				mesh.index_buffer:GetIndexType() == "uint32" and
				meshes.FLAG_INDEX_32 or
				0
			)
		record.index_address = tonumber(data.index_address)
		record.index_is_32 = mesh.index_buffer:GetIndexType() == "uint32"
	end

	meshes.GetTable():Get()[row].pool_first_index = index_pool.GetFirstIndex(mesh.index_buffer)
	record.raster_ready = true
end

function meshes.GetRecord(row)
	return records[row]
end

-- builds the bottom level structures that are waiting, within a budget of triangles per frame, and refits the ones of
-- meshes that were skinned (updated is a set of the addresses of their vertices)
function meshes.Build(cmd, updated)
	if not render.GetDevice().ray_tracing_supported then
		table.clear(pending)

		return false
	end

	local refit_count = 0
	local refit = {}

	if updated then
		for address in pairs(updated) do
			local record = dynamic_records[address]

			if record and record.blas then
				refit_count = refit_count + 1
				refit[refit_count] = record
			end
		end
	end

	if refit_count > 0 then
		accel.BuildBLASes(cmd, refit, refit_count)
	end

	local compacted, compacted_count = accel.CompactBLASes(cmd)

	if compacted_count > 0 then
		local rows = meshes.GetTable():Get()

		for i = 1, compacted_count do
			rows[compacted[i].row].blas_address = compacted[i].address
		end
	end

	if not pending[1] then return refit_count > 0 or compacted_count > 0 end

	local jobs = {}
	local budget = meshes.TRIANGLES_PER_FRAME
	local count = 0
	local taken = 0

	for i = 1, #pending do
		local record = pending[i]

		if records[record.row] == record and mesh_of_row[record.row] and mesh_of_row[record.row]:IsValid() then
			if count > 0 and budget < record.triangle_count then break end

			budget = budget - record.triangle_count
			count = count + 1
			jobs[count] = record
		end

		taken = i
	end

	local total = #pending
	table.move(pending, taken + 1, total, 1)

	for i = total - taken + 1, total do
		pending[i] = nil
	end

	if count == 0 then return false end

	accel.BuildBLASes(cmd, jobs, count)
	local rows = meshes.GetTable():Get()

	for i = 1, count do
		rows[jobs[i].row].blas_address = jobs[i].address
	end

	return true
end

function meshes.GetTriangleCount()
	return triangle_total
end

function meshes.GetPendingCount()
	return #pending
end

-- rows whose mesh is gone are released a few at a time
function meshes.Update()
	local rows = meshes.GetTable()
	local top = rows.count

	if top == 0 then return end

	for _ = 1, math.min(SWEEP_ROWS, top) do
		sweep_cursor = sweep_cursor % top
		local row = sweep_cursor
		sweep_cursor = sweep_cursor + 1
		local record = records[row]

		if record and not mesh_of_row[row] then
			accel.ReleaseBLAS(record)
			dynamic_records[record.vertex_address] = nil
			triangle_total = triangle_total - record.triangle_count
			records[row] = nil
			rows:Free(row)
		end
	end
end

return meshes
