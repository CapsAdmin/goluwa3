local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local pvars = import("goluwa/cli/pvars.lua")
local cluster_lod = import("goluwa/render3d/cluster_lod/cluster_lod.lua")
local format = import("goluwa/render3d/cluster_lod/format.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local index_pool = import("goluwa/render3d/index_pool.lua")
local vk = vulkan.vk
local cluster_rt = {}
local OP_BUILD_CLUSTERS_BOTTOM_LEVEL = 1
local OP_BUILD_TRIANGLE_CLUSTER = 2
local MODE_IMPLICIT = 0
local FORMAT_R32G32B32_SFLOAT = 106
local INDEX_FORMAT_8BIT = 1
local BUILD_PREFER_FAST_TRACE = 4
local NO_JOB = 0xFFFFFFFF
local RING = 3
local BLAS_INFO_BYTES = 16
local TriangleClusterArgs = ffi.typeof([[struct {
	uint32_t cluster_id;
	uint32_t cluster_flags;
	uint32_t counts;
	uint32_t geometry;
	uint16_t index_stride;
	uint16_t vertex_stride;
	uint16_t geometry_stride;
	uint16_t micromap_index_stride;
	uint64_t index_buffer;
	uint64_t vertex_buffer;
	uint64_t geometry_buffer;
	uint64_t micromap_array;
	uint64_t micromap_index_buffer;
}]])
assert(ffi.sizeof(TriangleClusterArgs) == 64)
local TriangleClusterArgsPointer = ffi.typeof("$ *", TriangleClusterArgs)
local JobType = ffi.typeof([[struct {
	uint32_t instance;
	uint32_t record_base;
	uint32_t record_count;
	uint32_t pair_base;
	uint64_t sub_ranges;
	uint64_t clas_addresses;
	uint32_t ref_base;
	uint32_t pad;
}]])
local JobPointer = ffi.typeof("$ *", JobType)
local BLASInfo = ffi.typeof("struct { uint32_t count; uint32_t stride; uint64_t address; }")
assert(ffi.sizeof(BLASInfo) == BLAS_INFO_BYTES)
local BLASInfoPointer = ffi.typeof("$ *", BLASInfo)
local SizesInfo = ffi.typeof("$[1]", vk.VkAccelerationStructureBuildSizesInfoKHR)
local TriangleInput = ffi.typeof("$[1]", vk.VkClusterAccelerationStructureTriangleClusterInputNV)
local BottomLevelInput = ffi.typeof("$[1]", vk.VkClusterAccelerationStructureClustersBottomLevelInputNV)
local CommandsInfo = ffi.typeof("$[1]", vk.VkClusterAccelerationStructureCommandsInfoNV)

local function invalidate_scene()
	import("goluwa/entities/components/visual.lua").Library.InvalidateSceneAcceleration()
end

pvars.StartGroup("Rendering", "Ray tracing", {store = false})
local enabled = pvars.Setup2{
	key = "r_rt_clusters",
	default = true,
	callback = invalidate_scene,
	help = "trace cluster lod models through cluster acceleration structures, one bottom level structure per instance built every frame from a cut picked on the gpu, instead of the fixed cuts",
}
pvars.EndGroup()

function cluster_rt.IsEnabled()
	return enabled:Get() and render.GetDevice().cluster_acceleration_structure_supported
end

local properties

local function get_properties()
	properties = properties or
		render.GetPhysicalDevice():GetClusterAccelerationStructureProperties()
	return properties
end

local function create_buffer(byte_size, usage, label, host)
	return render.CreateBuffer{
		byte_size = math.max(byte_size, 16),
		buffer_usage = usage,
		memory_property = host and {"host_visible", "host_coherent"} or {"device_local"},
		label = label,
	}
end

local function build_sizes(input)
	local sizes = SizesInfo()
	sizes[0].sType = vk.VkStructureType.VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR
	local device = render.GetDevice()
	device:GetExtension("vkGetClusterAccelerationStructureBuildSizesNV")(device.ptr[0], input, sizes)
	return tonumber(sizes[0].accelerationStructureSize),
	tonumber(sizes[0].buildScratchSize)
end

local function new_input(op, count)
	local commands = CommandsInfo()
	commands[0].sType = vk.VkStructureType.VK_STRUCTURE_TYPE_CLUSTER_ACCELERATION_STRUCTURE_COMMANDS_INFO_NV
	local input = commands[0].input
	input.sType = vk.VkStructureType.VK_STRUCTURE_TYPE_CLUSTER_ACCELERATION_STRUCTURE_INPUT_INFO_NV
	input.maxAccelerationStructureCount = count
	input.flags = BUILD_PREFER_FAST_TRACE
	input.opType = op
	input.opMode = MODE_IMPLICIT
	return commands
end

local scratch

local function ensure_scratch(size)
	if scratch and scratch:GetSize() >= size then return scratch end

	if scratch then
		render.GetDevice():WaitIdle()
		scratch:Remove()
	end

	scratch = create_buffer(size, {"shader_device_address", "storage_buffer"}, "cluster_rt_scratch")
	return scratch
end

local hierarchies = setmetatable({}, {__mode = "k"})
local pending_builds = {}
local retired = {}

local function retire(list)
	retired[#retired + 1] = {frame = system.GetFrameNumber(), buffers = list}
end

local function collect_retired()
	local frame = system.GetFrameNumber()
	local keep = {}

	for _, item in ipairs(retired) do
		if frame - item.frame > RING + 1 then
			for _, buffer in ipairs(item.buffers) do
				buffer:Remove()
			end
		else
			keep[#keep + 1] = item
		end
	end

	retired = keep
end

local function bake(polygon3d, state, records, indices, pool_first)
	local packed = polygon3d.packed
	local vertices = packed.vertices
	local props = get_properties()
	local max_vertices = math.min(props.maxVerticesPerCluster, 256)
	local max_triangles = math.min(props.maxTrianglesPerCluster, 511)
	local sub_ranges = ffi.new("uint32_t[?]", state.count * 2)
	local reference_capacity = 0

	for c = 0, state.count - 1 do
		reference_capacity = reference_capacity + records[c].index_count
	end

	local sub_vertices = ffi.new("uint32_t[?]", reference_capacity)
	local local_indices = ffi.new("uint8_t[?]", reference_capacity)
	local slot_stamps = ffi.new("int32_t[?]", packed.vertex_count)
	local slot_indices = ffi.new("uint8_t[?]", packed.vertex_count)
	local sub_cluster_ids, sub_triangle_counts, sub_vertex_counts = {}, {}, {}
	local sub_count, position_total, index_total = 0, 0, 0
	local max_cluster_vertices, max_cluster_triangles = 0, 0
	local stamp = 0

	for c = 0, state.count - 1 do
		local record = records[c]
		local first_index = record.first_index
		local triangles = record.index_count / 3
		sub_ranges[c * 2] = sub_count
		local first_triangle, vertex_count = 0, 0
		stamp = stamp + 1

		for t = 0, triangles do
			local at = first_index + t * 3
			local new = 0

			if t < triangles then
				for k = 0, 2 do
					if slot_stamps[indices[at + k]] ~= stamp then new = new + 1 end
				end
			end

			local count = t - first_triangle

			if
				count > 0 and
				(
					t == triangles or
					vertex_count + new > max_vertices or
					count >= max_triangles
				)
			then
				sub_count = sub_count + 1
				sub_cluster_ids[sub_count] = (pool_first + first_index) / 3 + first_triangle
				sub_triangle_counts[sub_count] = count
				sub_vertex_counts[sub_count] = vertex_count
				position_total = position_total + vertex_count
				index_total = index_total + count * 3
				max_cluster_vertices = math.max(max_cluster_vertices, vertex_count)
				max_cluster_triangles = math.max(max_cluster_triangles, count)
				first_triangle, vertex_count = t, 0
				stamp = stamp + 1
			end

			if t < triangles then
				local index_at = index_total + (t - first_triangle) * 3

				for k = 0, 2 do
					local index = indices[at + k]

					if slot_stamps[index] ~= stamp then
						slot_stamps[index] = stamp
						slot_indices[index] = vertex_count
						sub_vertices[position_total + vertex_count] = index
						vertex_count = vertex_count + 1
					end

					local_indices[index_at + k] = slot_indices[index]
				end
			end
		end

		sub_ranges[c * 2 + 1] = sub_count - sub_ranges[c * 2]
	end

	local positions_offset = 0
	local indices_offset = math.ceil(position_total * 12 / 16) * 16
	local args_offset = math.ceil((indices_offset + index_total) / 64) * 64
	local count_offset = args_offset + sub_count * 64
	local ranges_offset = count_offset + 16
	local input = create_buffer(
		ranges_offset + state.count * 8,
		{
			"shader_device_address",
			"storage_buffer",
			"acceleration_structure_build_input_read_only_khr",
		},
		"cluster_rt_input",
		true
	)
	local mapped = ffi.cast("uint8_t *", input:Map())
	local positions = ffi.cast("float *", mapped + positions_offset)
	local args = ffi.cast(TriangleClusterArgsPointer, mapped + args_offset)
	local base = input:GetDeviceAddress()
	local position_at, index_at = 0, 0

	for i = 1, sub_count do
		local arg = args[i - 1]
		arg.cluster_id = sub_cluster_ids[i]
		arg.cluster_flags = 0
		arg.counts = sub_triangle_counts[i] + sub_vertex_counts[i] * 512 + INDEX_FORMAT_8BIT * 16777216
		arg.geometry = 0
		arg.index_stride = 1
		arg.vertex_stride = 12
		arg.geometry_stride = 0
		arg.micromap_index_stride = 0
		arg.index_buffer = base + indices_offset + index_at
		arg.vertex_buffer = base + positions_offset + position_at * 12
		arg.geometry_buffer = 0
		arg.micromap_array = 0
		arg.micromap_index_buffer = 0
		position_at = position_at + sub_vertex_counts[i]
		index_at = index_at + sub_triangle_counts[i] * 3
	end

	for i = 0, position_total - 1 do
		local position = vertices[sub_vertices[i]].position
		positions[i * 3] = position[0]
		positions[i * 3 + 1] = position[1]
		positions[i * 3 + 2] = position[2]
	end

	ffi.copy(mapped + indices_offset, local_indices, index_total)
	ffi.cast("uint32_t *", mapped + count_offset)[0] = sub_count
	ffi.copy(mapped + ranges_offset, sub_ranges, state.count * 8)
	local commands = new_input(OP_BUILD_TRIANGLE_CLUSTER, sub_count)
	local triangle_input = TriangleInput()
	triangle_input[0].sType = vk.VkStructureType.VK_STRUCTURE_TYPE_CLUSTER_ACCELERATION_STRUCTURE_TRIANGLE_CLUSTER_INPUT_NV
	triangle_input[0].vertexFormat = FORMAT_R32G32B32_SFLOAT
	triangle_input[0].maxGeometryIndexValue = 0
	triangle_input[0].maxClusterUniqueGeometryCount = 1
	triangle_input[0].maxClusterTriangleCount = max_cluster_triangles
	triangle_input[0].maxClusterVertexCount = max_cluster_vertices
	triangle_input[0].maxTotalTriangleCount = index_total / 3
	triangle_input[0].maxTotalVertexCount = position_total
	triangle_input[0].minPositionTruncateBitCount = 0
	commands[0].input.opInput.pTriangleClusters = triangle_input
	local storage_size, scratch_size = build_sizes(commands[0].input)
	local storage = create_buffer(
		storage_size,
		{"acceleration_structure_storage_khr", "shader_device_address"},
		"cluster_rt_clas"
	)
	local addresses = create_buffer(
		sub_count * 8,
		{"shader_device_address", "storage_buffer", "transfer_src"},
		"cluster_rt_clas_addresses"
	)
	local hierarchy = {
		record_base = state.base,
		record_count = state.count,
		sub_count = sub_count,
		input = input,
		storage = storage,
		addresses = addresses,
		sub_ranges_address = base + ranges_offset,
		clas_addresses_address = addresses:GetDeviceAddress(),
		built = false,
		commands = commands,
		triangle_input = triangle_input,
		scratch_size = scratch_size,
		args_address = base + args_offset,
		count_address = base + count_offset,
		guard = ffi.gc(ffi.new("char[1]"), function()
			retire({input, storage, addresses})
		end),
	}
	hierarchies[polygon3d] = hierarchy
	pending_builds[#pending_builds + 1] = hierarchy
end

cluster_lod.listeners[#cluster_lod.listeners + 1] = function(polygon3d, state, records, indices, pool_first)
	if not cluster_rt.IsEnabled() or not polygon3d or not polygon3d.packed then
		return
	end

	bake(polygon3d, state, records, indices, pool_first)
end

local function build_pending(cmd)
	if not pending_builds[1] then return end

	local cmd_build = render.GetDevice():GetExtension("vkCmdBuildClusterAccelerationStructureIndirectNV")

	for _, hierarchy in ipairs(pending_builds) do
		local buffer = ensure_scratch(hierarchy.scratch_size)
		local commands = hierarchy.commands
		commands[0].input.opInput.pTriangleClusters = hierarchy.triangle_input
		commands[0].dstImplicitData = hierarchy.storage:GetDeviceAddress()
		commands[0].scratchData = buffer:GetDeviceAddress()
		commands[0].dstAddressesArray.deviceAddress = hierarchy.clas_addresses_address
		commands[0].dstAddressesArray.stride = 8
		commands[0].dstAddressesArray.size = hierarchy.sub_count * 8
		commands[0].srcInfosArray.deviceAddress = hierarchy.args_address
		commands[0].srcInfosArray.stride = 64
		commands[0].srcInfosArray.size = hierarchy.sub_count * 64
		commands[0].srcInfosCount = hierarchy.count_address
		cmd:PipelineBarrier{
			srcStage = {"acceleration_structure_build_khr", "compute"},
			dstStage = "acceleration_structure_build_khr",
			memoryBarrier = true,
		}
		cmd_build(cmd.ptr[0], commands)
		hierarchy.built = true
		hierarchy.commands = nil
	end

	pending_builds = {}
	cmd:PipelineBarrier{
		srcStage = "acceleration_structure_build_khr",
		dstStage = {"compute", "acceleration_structure_build_khr"},
		memoryBarrier = true,
	}
end

local rows = {}
local row_serial = 0

function cluster_rt.SetInstance(id, polygon3d)
	if rows[id] ~= polygon3d then
		rows[id] = polygon3d
		row_serial = row_serial + 1
	end
end

function cluster_rt.ClearInstance(id)
	if rows[id] then
		rows[id] = nil
		row_serial = row_serial + 1
	end
end

function cluster_rt.IsReady(polygon3d)
	return hierarchies[polygon3d] ~= nil
end

local state = {
	built_serial = -1,
	job_count = 0,
	pair_count = 0,
	ref_count = 0,
	max_refs = 0,
	job_capacity = 0,
	ref_capacity = 0,
	instance_capacity = 0,
	slots = {},
	ready = false,
}
local compute_block = {
	{"job_count", "int"},
	{"pair_count", "int"},
	{"jobs", "uint64_t"},
	{"clusters", "uint64_t"},
	{"tlas", "uint64_t"},
	{"refs", "uint64_t"},
	{"infos", "uint64_t"},
	unpack(cluster_lod.VIEW_BLOCK),
}
local select_pipeline

local function get_select_pipeline()
	if select_pipeline then return select_pipeline end

	select_pipeline = EasyPipeline.Compute{
		name = "cluster_rt_select",
		LocalSize = {x = 64, y = 1, z = 1},
		block = compute_block,
		write = function(self, block)
			cluster_lod.WriteView(block)
			block.job_count = state.job_count
			block.pair_count = state.pair_count
			block.jobs = state.jobs_address
			block.clusters = cluster_lod.GetTable():GetAddress()
			block.tlas = import("goluwa/render3d/scene/instances.lua").GetTables():GetAddress()
			block.refs = state.refs_address
			block.infos = state.infos_address
			return block
		end,
		shader = [[
			#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
			]] .. format.CLUSTER_GLSL .. [[
			struct cluster_job {
				uint instance;
				uint record_base;
				uint record_count;
				uint pair_base;
				uint64_t sub_ranges;
				uint64_t clas_addresses;
				uint ref_base;
				uint pad;
			};

			struct tlas_instance {
				float m[12];
				uint custom_and_mask;
				uint flags;
				uint64_t blas;
			};

			layout(buffer_reference, scalar) readonly buffer JobArray { cluster_job j[]; };
			layout(buffer_reference, scalar) readonly buffer ClusterArray { cluster_record c[]; };
			layout(buffer_reference, scalar) readonly buffer TLASArray { tlas_instance t[]; };
			layout(buffer_reference, scalar) readonly buffer RangeArray { uvec2 r[]; };
			layout(buffer_reference, scalar) readonly buffer AddressArray { uint64_t a[]; };
			layout(buffer_reference, scalar) buffer RefArray { uint64_t a[]; };
			layout(buffer_reference, scalar) buffer InfoArray { uvec4 i[]; };

			vec3 transform_point(float m[12], vec3 p) {
				return vec3(
					dot(vec3(m[0], m[1], m[2]), p) + m[3],
					dot(vec3(m[4], m[5], m[6]), p) + m[7],
					dot(vec3(m[8], m[9], m[10]), p) + m[11]
				);
			}

			]] .. cluster_lod.GetViewGLSL("compute") .. [[

			void main() {
				uint g = gl_GlobalInvocationID.x;

				if (g >= uint(compute.pair_count)) return;

				JobArray jobs = JobArray(compute.jobs);
				uint lo = 0u;
				uint hi = uint(compute.job_count) - 1u;

				while (lo < hi) {
					uint mid = (lo + hi + 1u) >> 1;

					if (jobs.j[mid].pair_base <= g) lo = mid; else hi = mid - 1u;
				}

				cluster_job job = jobs.j[lo];
				uint r = g - job.pair_base;

				if (r >= job.record_count) return;

				cluster_record c = ClusterArray(compute.clusters).c[job.record_base + r];
				tlas_instance t = TLASArray(compute.tlas).t[job.instance];
				float scale = max(length(vec3(t.m[0], t.m[4], t.m[8])), max(length(vec3(t.m[1], t.m[5], t.m[9])), length(vec3(t.m[2], t.m[6], t.m[10]))));

				if (!cluster_lod_fine_enough(c.error * scale, transform_point(t.m, c.lod.xyz), c.lod.w * scale)) return;
				if (c.parent_error < 1e29 && cluster_lod_fine_enough(c.parent_error * scale, transform_point(t.m, c.parent.xyz), c.parent.w * scale)) return;

				uvec2 range = RangeArray(job.sub_ranges).r[r];
				uint at = atomicAdd(InfoArray(compute.infos).i[lo].x, range.y);
				AddressArray clas = AddressArray(job.clas_addresses);
				RefArray refs = RefArray(compute.refs);

				for (uint s = 0u; s < range.y; s++) {
					refs.a[job.ref_base + at + s] = clas.a[range.x + s];
				}
			}
		]],
	}
	return select_pipeline
end

local function power_of_two(value, minimum)
	return math.max(minimum, 2 ^ math.ceil(math.log(math.max(value, 1)) / math.log(2)))
end

local function ensure_capacity(job_count, ref_count, max_refs, instance_capacity)
	local grow_jobs = job_count > state.job_capacity
	local grow_refs = ref_count > state.ref_capacity or max_refs > state.max_refs
	local grow_instances = instance_capacity > state.instance_capacity

	if not (grow_jobs or grow_refs or grow_instances) then return end

	render.GetDevice():WaitIdle()
	state.job_capacity = math.max(state.job_capacity, power_of_two(job_count, 64))
	state.ref_capacity = math.max(state.ref_capacity, power_of_two(ref_count, 1024))
	state.max_refs = math.max(state.max_refs, power_of_two(max_refs, 256))
	state.instance_capacity = math.max(state.instance_capacity, power_of_two(instance_capacity, 1024))

	for _, key in ipairs{"jobs_buffer", "refs_buffer", "infos_buffer", "job_of_buffer"} do
		if state[key] then state[key]:Remove() end
	end

	for _, slot in ipairs(state.slots) do
		slot.storage:Remove()
		slot.addresses:Remove()
	end

	state.jobs_buffer = create_buffer(
		state.job_capacity * ffi.sizeof(JobType),
		{"shader_device_address", "storage_buffer", "transfer_dst"},
		"cluster_rt_jobs"
	)
	state.refs_buffer = create_buffer(
		state.ref_capacity * 8,
		{
			"shader_device_address",
			"storage_buffer",
			"acceleration_structure_build_input_read_only_khr",
		},
		"cluster_rt_refs"
	)
	state.infos_buffer = create_buffer(
		state.job_capacity * BLAS_INFO_BYTES + 16,
		{
			"shader_device_address",
			"storage_buffer",
			"transfer_dst",
			"acceleration_structure_build_input_read_only_khr",
			"transfer_src",
		},
		"cluster_rt_infos"
	)
	state.job_of_buffer = create_buffer(
		state.instance_capacity * 4,
		{"shader_device_address", "storage_buffer", "transfer_dst"},
		"cluster_rt_job_of"
	)
	state.jobs_address = state.jobs_buffer:GetDeviceAddress()
	state.refs_address = state.refs_buffer:GetDeviceAddress()
	state.infos_address = state.infos_buffer:GetDeviceAddress()
	state.job_count_address = state.infos_address + state.job_capacity * BLAS_INFO_BYTES
	state.jobs_cpu = ffi.new("uint8_t[?]", state.job_capacity * ffi.sizeof(JobType))
	state.infos_cpu = ffi.new("uint8_t[?]", state.job_capacity * BLAS_INFO_BYTES + 16)
	state.job_of_cpu = ffi.new("uint32_t[?]", state.instance_capacity)
	state.job_of_dirty = true
	local commands = new_input(OP_BUILD_CLUSTERS_BOTTOM_LEVEL, state.job_capacity)
	local bottom = BottomLevelInput()
	bottom[0].sType = vk.VkStructureType.VK_STRUCTURE_TYPE_CLUSTER_ACCELERATION_STRUCTURE_CLUSTERS_BOTTOM_LEVEL_INPUT_NV
	bottom[0].maxTotalClusterCount = state.ref_capacity
	bottom[0].maxClusterCountPerAccelerationStructure = state.max_refs
	commands[0].input.opInput.pClustersBottomLevel = bottom
	local storage_size, scratch_size = build_sizes(commands[0].input)
	state.blas_commands = commands
	state.blas_bottom = bottom
	state.blas_scratch_size = scratch_size
	state.slots = {}

	for i = 1, RING do
		state.slots[i] = {
			storage = create_buffer(
				storage_size,
				{"acceleration_structure_storage_khr", "shader_device_address"},
				"cluster_rt_blas"
			),
			addresses = create_buffer(
				state.job_capacity * 8,
				{"shader_device_address", "storage_buffer", "transfer_src"},
				"cluster_rt_blas_addresses"
			),
		}
	end
end

local function build_jobs()
	local instances = import("goluwa/render3d/scene/instances.lua")
	local tlas_table = instances.GetTables()

	if
		state.built_serial == row_serial and
		state.instance_capacity >= tlas_table.capacity
	then
		return
	end

	local list = {}
	local pairs_total, refs_total, max_refs = 0, 0, 0

	for id, polygon3d in pairs(rows) do
		local hierarchy = hierarchies[polygon3d]

		if hierarchy and hierarchy.built then
			list[#list + 1] = {id = id, hierarchy = hierarchy}
			pairs_total = pairs_total + hierarchy.record_count
			refs_total = refs_total + hierarchy.sub_count
			max_refs = math.max(max_refs, hierarchy.sub_count)
		end
	end

	ensure_capacity(#list, refs_total, max_refs, tlas_table.capacity)

	table.sort(list, function(a, b)
		return a.id < b.id
	end)

	local jobs = ffi.cast(JobPointer, state.jobs_cpu)
	local infos = ffi.cast(BLASInfoPointer, state.infos_cpu)
	ffi.fill(state.job_of_cpu, state.instance_capacity * 4, 0xFF)
	local pair_base, ref_base = 0, 0
	state.job_ids = {}

	for i, item in ipairs(list) do
		state.job_ids[i] = item.id
		local job = jobs[i - 1]
		local hierarchy = item.hierarchy
		job.instance = item.id
		job.record_base = hierarchy.record_base
		job.record_count = hierarchy.record_count
		job.pair_base = pair_base
		job.sub_ranges = hierarchy.sub_ranges_address
		job.clas_addresses = hierarchy.clas_addresses_address
		job.ref_base = ref_base
		infos[i - 1].count = 0
		infos[i - 1].stride = 8
		infos[i - 1].address = state.refs_address + ref_base * 8
		state.job_of_cpu[item.id] = i - 1
		pair_base = pair_base + hierarchy.record_count
		ref_base = ref_base + hierarchy.sub_count
	end

	ffi.cast("uint32_t *", state.infos_cpu + state.job_capacity * BLAS_INFO_BYTES)[0] = #list
	state.job_count = #list
	state.pair_count = pairs_total
	state.built_serial = row_serial
	state.job_of_dirty = true
end

local function upload(cmd, buffer, source, bytes, destination)
	local data = ffi.cast("uint8_t *", source)
	destination = destination or 0

	for offset = 0, bytes - 1, 65536 do
		cmd:UpdateBuffer(buffer, destination + offset, math.min(65536, bytes - offset), data + offset)
	end
end

function cluster_rt.Build(cmd)
	state.ready = false
	collect_retired()

	if not cluster_rt.IsEnabled() then return end

	build_pending(cmd)
	meshes.SetClusterIndexAddress(index_pool.GetBuffer():GetDeviceAddress())

	if not next(rows) then return end

	build_jobs()

	if state.job_count == 0 then return end

	local slot = state.slots[system.GetFrameNumber() % RING + 1]
	cmd:PipelineBarrier{
		srcStage = "all_commands",
		dstStage = "transfer",
		memoryBarrier = true,
	}
	upload(cmd, state.jobs_buffer, state.jobs_cpu, state.job_count * ffi.sizeof(JobType))
	upload(cmd, state.infos_buffer, state.infos_cpu, state.job_count * BLAS_INFO_BYTES)
	upload(
		cmd,
		state.infos_buffer,
		state.infos_cpu + state.job_capacity * BLAS_INFO_BYTES,
		4,
		state.job_capacity * BLAS_INFO_BYTES
	)

	if state.job_of_dirty then
		upload(cmd, state.job_of_buffer, state.job_of_cpu, state.instance_capacity * 4)
		state.job_of_dirty = false
	end

	cmd:PipelineBarrier{srcStage = "transfer", dstStage = "compute", memoryBarrier = true}
	get_select_pipeline():Dispatch(cmd, math.ceil(state.pair_count / 64), 1, 1, 1)
	cmd:PipelineBarrier{
		srcStage = "compute",
		dstStage = "acceleration_structure_build_khr",
		memoryBarrier = true,
	}
	local commands = state.blas_commands
	commands[0].input.opInput.pClustersBottomLevel = state.blas_bottom
	commands[0].dstImplicitData = slot.storage:GetDeviceAddress()
	commands[0].scratchData = ensure_scratch(state.blas_scratch_size):GetDeviceAddress()
	commands[0].dstAddressesArray.deviceAddress = slot.addresses:GetDeviceAddress()
	commands[0].dstAddressesArray.stride = 8
	commands[0].dstAddressesArray.size = state.job_capacity * 8
	commands[0].srcInfosArray.deviceAddress = state.infos_address
	commands[0].srcInfosArray.stride = BLAS_INFO_BYTES
	commands[0].srcInfosArray.size = state.job_capacity * BLAS_INFO_BYTES
	commands[0].srcInfosCount = state.job_count_address
	render.GetDevice():GetExtension("vkCmdBuildClusterAccelerationStructureIndirectNV")(cmd.ptr[0], commands)
	cmd:PipelineBarrier{
		srcStage = "acceleration_structure_build_khr",
		dstStage = {"compute", "acceleration_structure_build_khr"},
		memoryBarrier = true,
	}
	state.blas_addresses_address = slot.addresses:GetDeviceAddress()
	state.last_slot = slot
	state.ready = true
end

function cluster_rt.GetTLASOverride()
	if not state.ready then return 0, 0, 0 end

	return state.job_of_buffer:GetDeviceAddress(),
	state.blas_addresses_address,
	state.instance_capacity
end

function cluster_rt.ReadSelectedCounts()
	local counts = {}

	if not state.ready then return counts end

	local bytes = state.job_count * BLAS_INFO_BYTES
	local staging = create_buffer(bytes, {"transfer_dst"}, "cluster_rt_readback", true)
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	local region = ffi.new(ffi.typeof("$[1]", vk.VkBufferCopy))
	region[0].size = bytes
	cmd:CopyBuffer(state.infos_buffer, staging, region, 1)
	cmd:End()
	render.SubmitAndWait(cmd)
	cmd:Remove()
	local infos = ffi.cast(BLASInfoPointer, staging:Map())

	for i, id in ipairs(state.job_ids) do
		counts[id] = infos[i - 1].count
	end

	staging:Remove()
	return counts
end

function cluster_rt.GetStats()
	local hierarchy_count, clas_count = 0, 0

	for _, hierarchy in pairs(hierarchies) do
		hierarchy_count = hierarchy_count + 1
		clas_count = clas_count + hierarchy.sub_count
	end

	return {
		hierarchies = hierarchy_count,
		clas = clas_count,
		instances = state.job_count,
		refs = state.ref_capacity,
	}
end

return cluster_rt
