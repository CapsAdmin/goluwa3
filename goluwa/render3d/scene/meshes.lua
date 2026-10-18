local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local store = import("goluwa/render3d/scene/store.lua")
local accel = import("goluwa/render3d/scene/accel.lua")
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
	uint32_t pad;
}]])
meshes.FLAG_INDEX_32 = 1
meshes.FLAG_HAS_INDICES = 2
meshes.TRIANGLES_PER_FRAME = 8 * 1024 * 1024
local table_rows
local by_mesh = setmetatable({}, {__mode = "k"})
local mesh_of_row = setmetatable({}, {__mode = "v"})
local records = {}
local pending = {}
local sweep_cursor = 0
local SWEEP_ROWS = 256

function meshes.GetTable()
	table_rows = table_rows or
		store.CreateTable{name = "meshes", ctype = MeshRow, capacity = 16384}
	return table_rows
end

-- the row of a mesh, which is built for ray tracing once and kept for as long as the mesh lives. nil for a mesh the gpu
-- has no buffers of
function meshes.Get(mesh)
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
		vertex_address = data.vertex_address,
		vertex_stride = data.vertex_stride,
		vertex_count = vertex_buffer:GetVertexCount(),
		index_address = tonumber(data.index_address),
		index_is_32 = index_buffer and index_buffer:GetIndexType() == "uint32",
		triangle_count = triangle_count,
		address = 0,
	}
	records[row] = record
	pending[#pending + 1] = record
	return row
end

function meshes.GetRecord(row)
	return records[row]
end

-- builds the bottom level structures that are waiting, within a budget of triangles per frame
function meshes.Build(cmd)
	if not pending[1] then return false end

	local jobs = {}
	local budget = meshes.TRIANGLES_PER_FRAME
	local count = 0
	local taken = 0

	for i = 1, #pending do
		local record = pending[i]

		if records[record.row] == record then
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
			records[row] = nil
			rows:Free(row)
		end
	end
end

return meshes
