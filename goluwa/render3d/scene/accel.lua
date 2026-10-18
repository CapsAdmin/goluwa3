local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local AccelerationStructure = import("goluwa/render/vulkan/internal/acceleration_structure.lua")
local accel = {}
local vk = vulkan.vk
local VkRangeInfoArray = ffi.typeof("$[?]", vk.VkAccelerationStructureBuildRangeInfoKHR)
local VkRangePointerArray = ffi.typeof("const $*[?]", vk.VkAccelerationStructureBuildRangeInfoKHR)
local VkGeometryArray = ffi.typeof("$[?]", vk.VkAccelerationStructureGeometryKHR)
local VkBuildInfoArray = ffi.typeof("$[?]", vk.VkAccelerationStructureBuildGeometryInfoKHR)
local VK_GEOMETRY_TYPE_TRIANGLES = 0
local VK_GEOMETRY_TYPE_INSTANCES = 2
local VK_INDEX_TYPE_UINT16 = 0
local VK_INDEX_TYPE_UINT32 = 1
local VK_INDEX_TYPE_NONE = 1000165000
local BUILD_ALLOW_UPDATE = 1
local BUILD_PREFER_FAST_TRACE = 4
local BUILD_MODE_UPDATE = 1
local BLAS_ALIGN = 256
local BLAS_POOL_BYTES = 256 * 1024 * 1024
local SCRATCH_BUDGET = 256 * 1024 * 1024
local TLAS_SLOT_COUNT = 4
accel.INSTANCE_BYTE_SIZE = ffi.sizeof(vk.VkAccelerationStructureInstanceKHR)
accel.INSTANCE_FACING_CULL_DISABLE = 0x01000000
accel.INSTANCE_FORCE_OPAQUE = 0x04000000
accel.INSTANCE_FORCE_NO_OPAQUE = 0x08000000
local pools = {}
local pending_free = {}
local tlas_slots = {}
local current_slot
local placeholder
local scratch
local scratch_address
local scratch_alignment

local function range_class(n)
	if n <= 16 then return n end

	local step = 1

	while step * 16 <= n do
		step = step * 2
	end

	return math.ceil(n / step) * step
end

local function pool_alloc(size)
	local units = range_class(math.ceil(size / BLAS_ALIGN))

	for _, pool in ipairs(pools) do
		local list = pool.free[units]

		if list and list[1] then
			local offset = list[#list]
			list[#list] = nil
			return pool, offset, units
		end

		if pool.top + units <= pool.capacity then
			local offset = pool.top
			pool.top = pool.top + units
			return pool, offset, units
		end
	end

	local capacity = math.max(math.ceil(BLAS_POOL_BYTES / BLAS_ALIGN), units)
	local pool = {
		buffer = render.CreateBuffer{
			byte_size = capacity * BLAS_ALIGN,
			buffer_usage = {"acceleration_structure_storage_khr", "shader_device_address"},
			memory_property = {"device_local"},
			label = "scene_blas_pool",
		},
		capacity = capacity,
		top = units,
		free = {},
	}
	pools[#pools + 1] = pool
	return pool, 0, units
end

function accel.ReleaseBLAS(record)
	if not record.blas then return end

	pending_free[#pending_free + 1] = {
		frame = system.GetFrameNumber(),
		pool = record.pool,
		offset = record.offset,
		units = record.units,
		blas = record.blas,
	}
	record.blas = nil
	record.pool = nil
	record.address = 0
end

function accel.Update()
	local frame = system.GetFrameNumber()
	local delay = render.GetSwapchainImageCount() + 1
	local keep = {}

	for _, item in ipairs(pending_free) do
		if item.frame <= frame - delay then
			local free = item.pool.free
			free[item.units] = free[item.units] or {}
			table.insert(free[item.units], item.offset)
			item.blas:Remove()
		else
			keep[#keep + 1] = item
		end
	end

	pending_free = keep
end

local function ensure_scratch(size)
	if scratch and scratch:GetSize() >= size then return end

	if scratch then
		scratch:Remove()
		render.GetDevice():WaitIdle()
	end

	scratch = render.CreateBuffer{
		byte_size = math.max(size, 1024 * 1024),
		buffer_usage = {"shader_device_address", "storage_buffer"},
		memory_property = {"device_local"},
		label = "scene_blas_scratch",
	}
	scratch_address = scratch:GetDeviceAddress()
end

local function barrier_between_builds(cmd)
	cmd:PipelineBarrier{
		srcStage = "acceleration_structure_build_khr",
		dstStage = "acceleration_structure_build_khr",
		bufferBarriers = {
			{
				buffer = scratch,
				srcAccessMask = "acceleration_structure_write_khr",
				dstAccessMask = "acceleration_structure_write_khr",
			},
		},
	}
end

-- a job is a mesh: {vertex_address, vertex_stride, vertex_count, index_address (0 for none), index_is_32, triangle_count,
-- allow_update}. blas, address, pool, offset, units and scratch_size are written to it
function accel.BuildBLASes(cmd, jobs, count)
	local device = render.GetDevice()
	scratch_alignment = scratch_alignment or
		math.max(
			tonumber(device.physical_device:GetAccelerationStructureProperties().minAccelerationStructureScratchOffsetAlignment),
			1
		)
	local geometries = VkGeometryArray(count)
	local infos = VkBuildInfoArray(count)
	local ranges = VkRangeInfoArray(count)
	local range_pointers = VkRangePointerArray(count)
	local scratch_sizes = {}
	local total = 0
	local largest = 0

	for i = 1, count do
		local job = jobs[i]
		local geometry = geometries[i - 1]
		geometry.sType = vk.VkStructureType.VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR
		geometry.geometryType = VK_GEOMETRY_TYPE_TRIANGLES
		-- the instance flags decide opaqueness, not the geometry
		local triangles = geometry.geometry.triangles
		triangles.sType = vk.VkStructureType.VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_TRIANGLES_DATA_KHR
		triangles.vertexFormat = vk.e.VkFormat("r32g32b32_sfloat")
		triangles.vertexData = job.vertex_address
		triangles.vertexStride = job.vertex_stride
		triangles.maxVertex = job.vertex_count - 1

		if job.index_address ~= 0 then
			triangles.indexType = job.index_is_32 and VK_INDEX_TYPE_UINT32 or VK_INDEX_TYPE_UINT16
			triangles.indexData = job.index_address
		else
			triangles.indexType = VK_INDEX_TYPE_NONE
		end

		local flags = job.allow_update and
			BUILD_PREFER_FAST_TRACE + BUILD_ALLOW_UPDATE or
			BUILD_PREFER_FAST_TRACE
		local update = job.blas ~= nil
		local scratch_size

		if update then
			scratch_size = job.scratch_size
		else
			local storage_size, build_scratch, update_scratch = AccelerationStructure.QueryBuildSize(
				device,
				{
					type = "bottom_level_khr",
					flags = flags,
					geometryCount = 1,
					pGeometries = geometry,
					maxPrimitiveCount = job.triangle_count,
				}
			)
			scratch_size = job.allow_update and math.max(build_scratch, update_scratch) or build_scratch
			job.scratch_size = scratch_size
			local pool, offset, units = pool_alloc(storage_size)
			job.pool = pool
			job.offset = offset
			job.units = units
			job.blas = AccelerationStructure.New(
				device,
				"bottom_level_khr",
				pool.buffer,
				offset * BLAS_ALIGN,
				units * BLAS_ALIGN
			)
			job.address = job.blas:Data()
		end

		scratch_size = math.ceil(scratch_size / scratch_alignment) * scratch_alignment
		scratch_sizes[i] = scratch_size
		total = total + scratch_size
		largest = math.max(largest, scratch_size)
		local info = infos[i - 1]
		info.sType = 1000150000
		info.type = 1
		info.flags = flags
		info.mode = update and BUILD_MODE_UPDATE or 0

		if update then info.srcAccelerationStructure = job.blas.ptr[0] end

		info.dstAccelerationStructure = job.blas.ptr[0]
		info.geometryCount = 1
		info.pGeometries = geometry
		ranges[i - 1].primitiveCount = job.triangle_count
		range_pointers[i - 1] = ranges + (i - 1)
	end

	ensure_scratch(math.max(math.min(SCRATCH_BUDGET, total), largest))
	local capacity = scratch:GetSize()
	local cmd_build = device:GetExtension("vkCmdBuildAccelerationStructuresKHR")
	cmd:PipelineBarrier{
		srcStage = "all_commands",
		dstStage = "acceleration_structure_build_khr",
		memoryBarrier = true,
	}
	local first = 0

	while first < count do
		local used = 0
		local n = 0

		while first + n < count do
			local size = scratch_sizes[first + n + 1]

			if used + size > capacity and n > 0 then break end

			infos[first + n].scratchData.deviceAddress = scratch_address + used
			used = used + size
			n = n + 1
		end

		cmd_build(cmd.ptr[0], n, infos + first, range_pointers + first)
		first = first + n

		if first < count then barrier_between_builds(cmd) end
	end

	-- the builds of the meshes are read by the tlas build and by ray queries
	cmd:PipelineBarrier{
		srcStage = "acceleration_structure_build_khr",
		dstStage = {"acceleration_structure_build_khr", "ray_tracing_shader_khr", "compute", "fragment"},
		memoryBarrier = true,
	}
end

local function create_tlas_slot(capacity)
	local slot = {capacity = capacity}
	slot.geometry = ffi.new(vk.VkAccelerationStructureGeometryKHR)
	slot.geometry.sType = vk.VkStructureType.VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR
	slot.geometry.geometryType = VK_GEOMETRY_TYPE_INSTANCES
	local instances = slot.geometry.geometry.instances
	instances.sType = vk.VkStructureType.VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_INSTANCES_DATA_KHR
	local storage_size, scratch_size = AccelerationStructure.QueryBuildSize(
		render.GetDevice(),
		{
			type = "top_level_khr",
			flags = BUILD_PREFER_FAST_TRACE,
			geometryCount = 1,
			pGeometries = slot.geometry,
			maxPrimitiveCount = capacity,
		}
	)
	slot.buffer = render.CreateBuffer{
		byte_size = storage_size,
		buffer_usage = {"acceleration_structure_storage_khr", "shader_device_address"},
		memory_property = {"device_local"},
		label = "scene_tlas",
	}
	slot.tlas = AccelerationStructure.New(render.GetDevice(), "top_level_khr", slot.buffer)
	slot.tlas:EnsureScratch(scratch_size)
	slot.last_used = -math.huge
	return slot
end

local function remove_tlas_slot(slot)
	slot.tlas:Remove()
	slot.buffer:Remove()
end

local function get_free_tlas_slot(frame, capacity)
	local delay = render.GetSwapchainImageCount() + 1

	for i = 1, TLAS_SLOT_COUNT do
		local slot = tlas_slots[i]

		if not slot or (slot ~= current_slot and slot.last_used <= frame - delay) then
			if slot and slot.capacity < capacity then
				remove_tlas_slot(slot)
				slot = nil
			end

			if not slot then
				slot = create_tlas_slot(math.max(capacity, 1024))
				tlas_slots[i] = slot
			end

			return slot
		end
	end
end

-- builds the top level structure from `count` records of an instance buffer. an unused record has a zero blas reference
function accel.BuildTLAS(cmd, instance_buffer, count)
	local frame = system.GetFrameNumber()
	local slot = get_free_tlas_slot(frame, count)

	if not slot then return current_slot and current_slot.tlas end

	slot.geometry.geometry.instances.data = instance_buffer:GetDeviceAddress()
	local ranges = VkRangeInfoArray(1)
	ranges[0].primitiveCount = count
	cmd:PipelineBarrier{
		srcStage = {"host", "compute", "transfer"},
		dstStage = "acceleration_structure_build_khr",
		memoryBarrier = true,
	}
	slot.tlas:Build(cmd, 1, slot.geometry, ranges, BUILD_PREFER_FAST_TRACE)
	cmd:PipelineBarrier{
		srcStage = "acceleration_structure_build_khr",
		dstStage = {"ray_tracing_shader_khr", "compute", "fragment"},
		bufferBarriers = {
			{
				buffer = slot.buffer,
				srcAccessMask = "acceleration_structure_write_khr",
				dstAccessMask = "acceleration_structure_read_khr",
			},
		},
	}
	slot.last_used = frame
	current_slot = slot
	return slot.tlas
end

-- the structure a frame traces against stays unwritten until the frames that may still use it are done
function accel.MarkTLASUsed()
	if current_slot then current_slot.last_used = system.GetFrameNumber() end
end

function accel.GetPlaceholderTLAS(cmd)
	if placeholder then return placeholder.tlas end

	local slot = create_tlas_slot(1)
	local ranges = VkRangeInfoArray(1)
	ranges[0].primitiveCount = 0
	slot.tlas:Build(cmd, 1, slot.geometry, ranges, BUILD_PREFER_FAST_TRACE)
	cmd:PipelineBarrier{
		srcStage = "acceleration_structure_build_khr",
		dstStage = {"ray_tracing_shader_khr", "compute", "fragment"},
		bufferBarriers = {
			{
				buffer = slot.buffer,
				srcAccessMask = "acceleration_structure_write_khr",
				dstAccessMask = "acceleration_structure_read_khr",
			},
		},
	}
	placeholder = slot
	return slot.tlas
end

return accel
