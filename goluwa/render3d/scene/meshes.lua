local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local checkpoints = import("goluwa/render/vulkan/internal/checkpoints.lua")
local store = import("goluwa/render3d/scene/store.lua")
local accel = import("goluwa/render3d/scene/accel.lua")
local index_pool = import("goluwa/render3d/index_pool.lua")
local meshes = {}
local MeshRow = ffi.typeof([[struct {
	uint64_t vertex_address;
	uint64_t index_address;
	uint64_t blas_address;
	uint64_t extras_address;
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

function meshes.Get(mesh, dynamic)
	local row = by_mesh[mesh]

	if row then return row end

	local vertex_buffer = mesh.vertex_buffer

	if not (vertex_buffer.buffer and mesh.mode == "triangle_list") then
		return nil
	end

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
	data.extras_address = mesh:GetExtrasBufferAddress()
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

	if dynamic then
		local list = dynamic_records[record.vertex_address]

		if not list then
			list = {}
			dynamic_records[record.vertex_address] = list
		end

		list[#list + 1] = record
	end

	triangle_total = triangle_total + triangle_count
	return row
end

function meshes.GetVariant(row)
	local source = records[row]
	local rows = meshes.GetTable()
	local variant = rows:Alloc()
	local data = rows:Get() + variant
	ffi.copy(data, rows:Get() + row, ffi.sizeof(MeshRow))
	data.blas_address = 0
	mesh_of_row[variant] = mesh_of_row[row]
	local record = {
		row = variant,
		vertex_address = source.vertex_address,
		vertex_stride = source.vertex_stride,
		vertex_count = source.vertex_count,
		index_address = source.index_address,
		index_is_32 = source.index_is_32,
		triangle_count = source.triangle_count,
		allow_update = false,
		address = 0,
	}
	records[variant] = record
	pending[#pending + 1] = record
	triangle_total = triangle_total + record.triangle_count
	return record
end

function meshes.GetCut(row, index_buffer, triangle_count)
	local source = records[row]
	local rows = meshes.GetTable()
	local cut = rows:Alloc()
	local data = rows:Get() + cut
	ffi.copy(data, rows:Get() + row, ffi.sizeof(MeshRow))
	data.blas_address = 0
	data.triangle_count = triangle_count
	data.index_address = index_buffer:GetBuffer():GetDeviceAddress()
	data.flags = meshes.FLAG_HAS_INDICES + meshes.FLAG_INDEX_32
	mesh_of_row[cut] = mesh_of_row[row]
	local record = {
		row = cut,
		vertex_address = source.vertex_address,
		vertex_stride = source.vertex_stride,
		vertex_count = source.vertex_count,
		index_address = tonumber(data.index_address),
		index_is_32 = true,
		triangle_count = triangle_count,
		allow_update = false,
		address = 0,
		index_buffer = index_buffer,
	}
	records[cut] = record
	pending[#pending + 1] = record
	triangle_total = triangle_total + triangle_count
	return cut
end

do
	local cluster_rows = {}
	local cluster_index_address = 0

	function meshes.GetClusterRow(row, index_address)
		local cluster_row = cluster_rows[row]

		if cluster_row then return cluster_row end

		local rows = meshes.GetTable()
		cluster_row = rows:Alloc()
		local data = rows:Get() + cluster_row
		ffi.copy(data, rows:Get() + row, ffi.sizeof(MeshRow))
		data.blas_address = 0
		data.index_address = index_address
		data.flags = meshes.FLAG_HAS_INDICES + meshes.FLAG_INDEX_32
		mesh_of_row[cluster_row] = mesh_of_row[row]
		cluster_rows[row] = cluster_row
		cluster_index_address = index_address
		return cluster_row
	end

	function meshes.SetClusterIndexAddress(index_address)
		if index_address == cluster_index_address then return end

		cluster_index_address = index_address
		local rows = meshes.GetTable()

		for _, cluster_row in pairs(cluster_rows) do
			rows:Get()[cluster_row].index_address = index_address
		end
	end
end

function meshes.RebuildBLAS(record)
	if record.blas then
		accel.ReleaseBLAS(record)
		pending[#pending + 1] = record
	end
end

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

local DESCRIBE_RANGE = 64 * 1024 * 1024

-- what a gpu address belongs to: the mesh buffer that contains it, or the nearest ones, for fault reports
function meshes.DescribeAddress(address, precision)
	local best = {}

	for row, record in pairs(records) do
		local index_size = record.index_is_32 and 4 or 2
		local ranges = {
			{"vertex", record.vertex_address, record.vertex_count * record.vertex_stride},
			{"index", record.index_address, record.triangle_count * 3 * index_size},
		}

		for _, range in ipairs(ranges) do
			local kind, first, size = range[1], range[2], range[3]

			if first ~= 0 then
				local distance = address < first and
					first - address or
					(
						address >= first + size and
						address - (
							first + size
						) + 1 or
						0
					)

				if distance <= DESCRIBE_RANGE then
					best[#best + 1] = {distance = distance, row = row, kind = kind, first = first, size = size}
				end
			end
		end
	end

	table.sort(best, function(a, b)
		return a.distance < b.distance
	end)

	local small = table.count(records) <= 8
	local listing = {}

	if small then
		local rows = meshes.GetTable():Get()

		for row, record in pairs(records) do
			listing[#listing + 1] = string.format(
				"row %d vertex 0x%x (%d x %d) index 0x%x (%d triangles, %s) blas 0x%x (record 0x%x) flags %d",
				row,
				record.vertex_address,
				record.vertex_count,
				record.vertex_stride,
				record.index_address,
				record.triangle_count,
				record.index_is_32 and "32 bit" or "16 bit",
				tonumber(rows[row].blas_address),
				record.address or 0,
				rows[row].flags
			)
		end
	end

	if #best == 0 then
		return (
				small and
				table.concat(listing, "\n    ") .. "\n    " or
				""
			) .. string.format(
				"no mesh buffer within %d MB of 0x%x (%d meshes)",
				DESCRIBE_RANGE / 1024 / 1024,
				address,
				table.count(records)
			)
	end

	local lines = {}

	for i = 1, math.min(#best, 3) do
		local b = best[i]
		local mesh = mesh_of_row[b.row]
		lines[#lines + 1] = string.format(
			"mesh row %d %s buffer 0x%x size %d: %s (%s)",
			b.row,
			b.kind,
			b.first,
			b.size,
			b.distance == 0 and
				"contains it" or
				string.format("%d bytes %s", b.distance, address < b.first and "before it" or "past its end"),
			mesh and tostring(mesh) or "mesh collected"
		)
	end

	return table.concat(lines, "\n    ")
end

table.insert(checkpoints.address_describers, meshes.DescribeAddress)

function meshes.GetRecord(row)
	return records[row]
end

function meshes.Build(cmd, updated)
	if not render.GetDevice().ray_tracing_supported then
		table.clear(pending)
		return false
	end

	local refit_count = 0
	local refit = {}

	if updated then
		for address in pairs(updated) do
			local list = dynamic_records[address]

			if list then
				for i = 1, #list do
					local record = list[i]

					if record.blas then
						refit_count = refit_count + 1
						refit[refit_count] = record
					end
				end
			end
		end
	end

	if refit_count > 0 then accel.BuildBLASes(cmd, refit, refit_count) end

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

		if
			records[record.row] == record and
			mesh_of_row[record.row] and
			mesh_of_row[record.row]:IsValid()
		then
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

			if record.omm and record.omm.micromap then record.omm.micromap:Remove() end

			if record.index_buffer then record.index_buffer:Remove() end

			local list = dynamic_records[record.vertex_address]

			if list then
				for i = 1, #list do
					if list[i] == record then
						table.remove(list, i)

						break
					end
				end

				if not list[1] then dynamic_records[record.vertex_address] = nil end
			end

			triangle_total = triangle_total - record.triangle_count
			records[row] = nil
			rows:Free(row)
		end
	end
end

return meshes
