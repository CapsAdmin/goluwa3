local ffi = require("ffi")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local store = import("goluwa/render3d/scene/store.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local accel = import("goluwa/render3d/scene/accel.lua")
local instances = {}
local TLASInstance = vulkan.vk.VkAccelerationStructureInstanceKHR
-- what the hit shaders read of an instance, the row has the same index as the record of the top level structure whose
-- custom index is that index
local InstanceData = ffi.typeof([[struct {
	uint32_t mesh_row;
	uint32_t material_row;
	uint32_t flags;
	uint32_t user;
}]])
instances.MASK_SOLID = 0x01
instances.MASK_SEE_THROUGH = 0x02
instances.FLAG_DOUBLE_SIDED = 1
instances.FLAG_ALPHA_TEST = 2
instances.FLAG_EMISSIVE = 4
instances.FLAG_NO_OPAQUE = 8
local tlas_table, data_table
local unresolved = {}
instances.version = 0

function instances.GetTables()
	if not tlas_table then
		tlas_table = store.CreateTable{
			name = "tlas_instances",
			ctype = TLASInstance,
			capacity = 4096,
			usage = {"shader_device_address", "acceleration_structure_build_input_read_only_khr"},
		}
		data_table = store.CreateTable{name = "instance_data", ctype = InstanceData, capacity = 4096}
	end

	return tlas_table, data_table
end

function instances.GetDataTable()
	return select(2, instances.GetTables())
end

-- the transform of the record is the world matrix as three rows of four
local function write_matrix(record, m)
	local t = record.transform.matrix
	t[0][0], t[0][1], t[0][2], t[0][3] = m.m00, m.m10, m.m20, m.m30
	t[1][0], t[1][1], t[1][2], t[1][3] = m.m01, m.m11, m.m21, m.m31
	t[2][0], t[2][1], t[2][2], t[2][3] = m.m02, m.m12, m.m22, m.m32
end

local function write_flags(record, data, mask, flags)
	record.sbrtAndFlags = accel.INSTANCE_FACING_CULL_DISABLE + (
			bit.band(flags, instances.FLAG_NO_OPAQUE) ~= 0 and
			accel.INSTANCE_FORCE_NO_OPAQUE or
			accel.INSTANCE_FORCE_OPAQUE
		)
	local id = tonumber(bit.band(record.customAndMask, 0xFFFFFF))
	record.customAndMask = id + mask * 0x1000000
	data.flags = flags
end

-- the blas reference stays zero (an inactive instance) until the mesh has been built
local function resolve(id)
	local tlas_rows = tlas_table:Get()
	local record = tlas_rows[id]
	local mesh_row = data_table:Get()[id].mesh_row
	local address = meshes.GetTable():Get()[mesh_row].blas_address
	record.accelerationStructureReference = address

	if address == 0 then
		unresolved[id] = true
	else
		unresolved[id] = nil
	end
end

-- mask 0 hides an instance from rays
function instances.Add(mesh_row, material_row, matrix, mask, flags)
	instances.GetTables()
	local id = tlas_table:Alloc()
	data_table:Reserve(tlas_table.capacity)
	data_table.count = tlas_table.count
	data_table.live = data_table.live + 1
	local record = tlas_table:Get()[id]
	local data = data_table:Get()[id]
	record.customAndMask = id
	data.mesh_row = mesh_row
	data.material_row = material_row
	write_matrix(record, matrix)
	write_flags(record, data, mask, flags)
	resolve(id)
	instances.version = instances.version + 1
	return id
end

function instances.Remove(id)
	tlas_table:Free(id)
	ffi.fill(data_table:Get() + id, ffi.sizeof(InstanceData))
	data_table.live = data_table.live - 1
	unresolved[id] = nil
	instances.version = instances.version + 1
end

function instances.SetMatrix(id, matrix)
	write_matrix(tlas_table:Get()[id], matrix)
	instances.version = instances.version + 1
end

function instances.SetMesh(id, mesh_row)
	data_table:Get()[id].mesh_row = mesh_row
	resolve(id)
	instances.version = instances.version + 1
end

function instances.SetMaterial(id, material_row)
	data_table:Get()[id].material_row = material_row
end

function instances.SetMask(id, mask, flags)
	local record = tlas_table:Get()[id]
	local data = data_table:Get()[id]
	local custom_and_mask = id + mask * 0x1000000

	if tonumber(record.customAndMask) == custom_and_mask and data.flags == flags then
		return
	end

	write_flags(record, data, mask, flags)
	instances.version = instances.version + 1
end

function instances.IsAlive()
	return tlas_table ~= nil and tlas_table.buffer:IsValid()
end

function instances.GetCount()
	return tlas_table and tlas_table.live or 0
end

-- builds what is waiting and the top level structure. the instance table is built in place, a freed record is all zero
-- and so inactive
function instances.Build(cmd)
	if not tlas_table then return nil end

	local built = meshes.Build(cmd)
	local rows = meshes.GetTable():Get()
	local data = data_table:Get()
	local tlas_rows = tlas_table:Get()

	for id in pairs(unresolved) do
		local address = rows[data[id].mesh_row].blas_address

		if address ~= 0 then
			tlas_rows[id].accelerationStructureReference = address
			unresolved[id] = nil
			instances.version = instances.version + 1
		end
	end

	if
		built or
		instances.built_version ~= instances.version or
		instances.built_generation ~= tlas_table.generation
	then
		instances.tlas = accel.BuildTLAS(cmd, tlas_table:GetBuffer(), math.max(tlas_table.count, 1))
		instances.built_version = instances.version
		instances.built_generation = tlas_table.generation
	end

	return instances.tlas
end

return instances
