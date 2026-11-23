local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local system = import("goluwa/system.lua")
local pvars = import("goluwa/cli/pvars.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local accel = import("goluwa/render3d/scene/accel.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local store = import("goluwa/render3d/scene/store.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local vegetation_pushers = import("goluwa/render3d/vegetation_pushers.lua")
local deformation = import("goluwa/render3d/deformation.lua")
local vegetation_bend = {}
pvars.StartGroup("Rendering", "Ray traced scene", {store = false})
local enabled = pvars.Setup2{
	key = "r_rt_bend",
	default = true,
	help = "plants that the wind bends are bent in the ray traced scene too, each a copy of its mesh deformed by the same bending as the raster and refit every frame. off, rays see every plant at rest and a bent surface's own rays start inside or beside its resting shape, which shades it as occluded",
}
local max_distance = pvars.Setup2{
	key = "r_rt_bend_distance",
	default = 80,
	help = "the farthest, in meters, a bending plant is bent in the ray traced scene. nearer it is bent while the wind moves it by at least a pixel (a blade of grass only close by, a tree much farther), beyond that it is traced at rest",
}
local bend_triangles = pvars.Setup2{
	key = "r_rt_bend_triangles",
	default = 262144,
	integer = true,
	help = "triangles of bent copies each bending mesh may have in the ray traced scene (a small mesh gets more copies than a large one), given to its instances within r_rt_bend_distance in no particular order. instances past the copies are traced at rest. copies are made as instances ask for them, and as many as asked are bent and refit every frame",
}
pvars.EndGroup()
local MAX_JOBS = 4096
local RING = 4
local LOCAL_SIZE = 64
local ROW = 65535
local animation_fields = {}
local animation_glsl = {}

for i, field in ipairs(deformation.GetBlock()) do
	local name, kind = field[1], field[2]
	animation_fields[i] = kind == "vec3" and
		"float " .. name .. "[3];" or
		(
			kind == "int" and
			"int32_t " .. name .. ";" or
			"float " .. name .. ";"
		)
	animation_glsl[i] = kind .. " " .. name .. ";"
end

local Animation = ffi.typeof("struct { " .. table.concat(animation_fields, " ") .. " }")
local Job = ffi.typeof(
	[[struct {
	uint32_t source[2];
	uint32_t destination[2];
	uint32_t instance[2];
	uint32_t count;
	uint32_t group_start;
	$ animation;
}]],
	Animation
)
local JobPtr = ffi.typeof("$ *", Job)
local uint64_ptr = ffi.typeof("uint64_t *")
local jobs_buffer, job_data
local pipeline
local job_base, job_count, group_count = 0, 0, 0
local bent = {}

local function get_pipeline()
	if pipeline then return pipeline end

	jobs_buffer = render.CreateBuffer{
		byte_size = ffi.sizeof(Job) * MAX_JOBS * RING,
		buffer_usage = {"storage_buffer"},
		memory_property = {"host_visible", "host_coherent"},
		label = "vegetation bend jobs",
	}
	job_data = ffi.cast(JobPtr, jobs_buffer:Map())
	pipeline = EasyPipeline.Compute{
		name = "vegetation_bend",
		DescriptorSetCount = 1,
		LocalSize = {x = LOCAL_SIZE, y = 1, z = 1},
		descriptor_sets = {
			{
				type = "storage_buffer",
				binding_index = 0,
				stageFlags = "compute",
				set_index = 0,
				args = function()
					return {jobs_buffer, jobs_buffer.size}
				end,
			},
		},
		block = {
			{"camera_position", "vec4"},
			{"pixel_scale", "float"},
			{"job_base", "int"},
			{"job_count", "int"},
			{"group_count", "int"},
		},
		write = function(self, block)
			local position, pixel_scale = deformation.GetView()
			block.camera_position[0] = position.x
			block.camera_position[1] = position.y
			block.camera_position[2] = position.z
			block.pixel_scale = pixel_scale
			block.job_base = job_base
			block.job_count = job_count
			block.group_count = group_count
			return block
		end,
		shader = [[
			layout(buffer_reference, scalar) readonly buffer BendSource { float v[]; };
			layout(buffer_reference, scalar) buffer BendDestination { float v[]; };
			layout(buffer_reference, scalar) readonly buffer BendInstance { float m[12]; };
			struct BendAnimation {
				]] .. table.concat(animation_glsl, "\n\t\t\t\t") .. [[
			};
			struct BendJob {
				uvec2 source;
				uvec2 destination;
				uvec2 instance;
				uint count;
				uint group_start;
				BendAnimation animation;
			};
			layout(scalar, set = 0, binding = 0) readonly buffer BendJobs {
				BendJob jobs[];
			};

			]] .. vertex_layout.BuildGlslAccessors("bend_source", "BendSource") .. [[

			BendAnimation vertex_animation;
			mat4 bend_world;

			]] .. deformation.BuildGlsl("bend_world", "compute.camera_position.xyz", "compute.pixel_scale") .. [[

			void main() {
				uint flat_group = gl_WorkGroupID.y * ]] .. ROW .. [[u + gl_WorkGroupID.x;

				if (flat_group >= uint(compute.group_count)) return;

				uint low = 0u;
				uint high = uint(compute.job_count);

				while (high - low > 1u) {
					uint middle = (low + high) / 2u;

					if (jobs[uint(compute.job_base) + middle].group_start <= flat_group) low = middle; else high = middle;
				}

				BendJob job = jobs[uint(compute.job_base) + low];
				uint i = (flat_group - job.group_start) * ]] .. LOCAL_SIZE .. [[u + gl_LocalInvocationID.x;

				if (i >= job.count) return;

				vertex_animation = job.animation;
				BendInstance instance = BendInstance(packUint2x32(job.instance));
				bend_world = mat4(
					vec4(instance.m[0], instance.m[4], instance.m[8], 0.0),
					vec4(instance.m[1], instance.m[5], instance.m[9], 0.0),
					vec4(instance.m[2], instance.m[6], instance.m[10], 0.0),
					vec4(instance.m[3], instance.m[7], instance.m[11], 1.0)
				);
				BendSource source = BendSource(packUint2x32(job.source));
				vec3 position = bend_source_position(source, i);
				position += inverse(mat3(bend_world)) * deform(position, bend_source_normal(source, i), i, bend_world, false).offset;
				BendDestination destination = BendDestination(packUint2x32(job.destination));
				destination.v[i * 3u] = position.x;
				destination.v[i * 3u + 1u] = position.y;
				destination.v[i * 3u + 2u] = position.z;
			}
		]],
	}
	return pipeline
end

function vegetation_bend.IsEnabled()
	return enabled:Get()
end

-- a positions only copy of the mesh that the bend writes and an acceleration structure over it with the mesh's indices, carrying the opacity micromap (the state of an opacity_micromaps variant) when there is one, which a refit must repeat
function vegetation_bend.NewRecord(mesh, omm)
	local positions = render.CreateBuffer{
		byte_size = mesh.vertex_count * 12,
		buffer_usage = {
			"storage_buffer",
			"shader_device_address",
			"acceleration_structure_build_input_read_only_khr",
		},
		memory_property = {"device_local"},
		label = "vegetation bend positions",
	}
	return {
		mesh = mesh,
		positions = positions,
		positions_address = positions:GetDeviceAddress(),
		blas_record = {
			vertex_address = tonumber(positions:GetDeviceAddress()),
			vertex_stride = 12,
			vertex_count = mesh.vertex_count,
			index_address = mesh.index_address,
			index_is_32 = mesh.index_is_32,
			triangle_count = mesh.triangle_count,
			allow_update = true,
			address = 0,
			omm = omm,
		},
	}
end

function vegetation_bend.ReleaseRecord(record)
	accel.ReleaseBLAS(record.blas_record)
	record.positions:Remove()
end

local function animates(animation)
	return animation.MainBending > 0 or
		animation.DetailBending ~= 0 and
		animation.BendSpeed > 0 or
		animation.PushBending > 0 and
		vegetation_pushers.GetData()[0] > 0
end

local scratch_animation = Animation()
local MIN_PIXELS = 1

-- how far from the camera a part with this material and polygon is bent: while the wind moves it by at least a pixel, 0 when it does not move
function vegetation_bend.GetRange(material, polygon)
	deformation.Fill(scratch_animation, material, polygon)

	if not animates(scratch_animation) then return 0 end

	local _, pixel_scale = deformation.GetView()
	return math.min(
		max_distance:Get(),
		deformation.GetMotion(scratch_animation) * pixel_scale / MIN_PIXELS
	)
end

local frame_stamp, frame_used = -1, 0
local queued, queued_groups = 0, 0
local queued_records = {}

-- vertices of the mesh at source are bent by the material's wind for the instance whose row major 3x4 world matrix is at matrix_address, into the record's positions
function vegetation_bend.Queue(record, source_address, matrix_address, material, polygon)
	local frame = system.GetFrameNumber()

	if frame ~= frame_stamp then
		frame_stamp = frame
		frame_used = 0
	end

	if frame_used + queued >= MAX_JOBS then return false end

	get_pipeline()
	local job = job_data[(frame % RING) * MAX_JOBS + frame_used + queued]
	deformation.Fill(job.animation, material, polygon)
	ffi.cast(uint64_ptr, job.source)[0] = source_address
	ffi.cast(uint64_ptr, job.destination)[0] = record.positions_address
	ffi.cast(uint64_ptr, job.instance)[0] = matrix_address
	job.count = record.mesh.vertex_count
	job.group_start = queued_groups
	queued_groups = queued_groups + math.ceil(record.mesh.vertex_count / LOCAL_SIZE)
	queued = queued + 1
	queued_records[queued] = record.blas_record
	return true
end

local function dispatch_queued(cmd)
	if queued == 0 then return end

	job_base = (system.GetFrameNumber() % RING) * MAX_JOBS + frame_used
	job_count = queued
	group_count = queued_groups
	cmd:PipelineBarrier{srcStage = "all_commands", dstStage = "compute", memoryBarrier = true}
	gpu_timing.BeginScope(cmd, "vegetation_bend")
	pipeline:Dispatch(cmd, math.min(queued_groups, ROW), math.ceil(queued_groups / ROW), 1, 1)
	gpu_timing.EndScope(cmd, "vegetation_bend")
	accel.BuildBLASes(cmd, queued_records, queued)

	for i = 1, queued do
		queued_records[i] = nil
	end

	frame_used = frame_used + queued
	queued, queued_groups = 0, 0
end

local Pool = ffi.typeof([[struct {
	uint32_t first_slot;
	uint32_t used;
	float range;
	uint32_t pad;
}]])
local BendSlot = ffi.typeof([[struct {
	float m[12];
	uint64_t blas;
}]])
local BufferCopy = ffi.typeof("$[1]", vulkan.vk.VkBufferCopy)
local READBACK_RING = 4
local pools_table, slots_table
local counters_buffer, readback_buffer, readback
local readback_copy = BufferCopy()
local active = {}
local pool_keys = {}

local function get_tables()
	if not pools_table then
		pools_table = store.CreateTable{name = "bend_pools", ctype = Pool, capacity = 256}
		slots_table = store.CreateTable{name = "bend_slots", ctype = BendSlot, capacity = 256}
		pools_table:Alloc()
	end

	return pools_table, slots_table
end

local function ensure_counters()
	local pools = get_tables()

	if counters_buffer and counters_buffer:GetSize() >= pools.capacity * 4 then
		return
	end

	if counters_buffer then
		counters_buffer:Remove()
		readback_buffer:Remove()
	end

	counters_buffer = render.CreateBuffer{
		byte_size = pools.capacity * 4,
		buffer_usage = {"storage_buffer", "transfer_dst", "transfer_src"},
		memory_property = {"device_local"},
		label = "vegetation_bend_counters",
	}
	readback_buffer = render.CreateBuffer{
		byte_size = pools.capacity * 4 * READBACK_RING,
		buffer_usage = {"transfer_dst"},
		memory_property = {"host_visible", "host_coherent"},
		label = "vegetation_bend_readback",
	}
	readback = ffi.cast("uint32_t *", readback_buffer:Map())
	ffi.fill(readback, pools.capacity * 4 * READBACK_RING)
end

function vegetation_bend.GetBindings()
	local pools, slots = get_tables()
	ensure_counters()
	return pools:GetBuffer(),
	pools:GetSize(),
	slots:GetBuffer(),
	slots:GetSize(),
	counters_buffer,
	counters_buffer:GetSize()
end

function vegetation_bend.GetAssignGLSL(pools_binding, slots_binding, counters_binding)
	return [[
		struct bend_pool {
			uint first_slot;
			uint used;
			float range;
			uint pad;
		};

		struct bend_slot {
			float m[12];
			uint64_t blas;
		};

		layout(scalar, set = 0, binding = ]] .. pools_binding .. [[) readonly buffer BendPools { bend_pool bend_pools[]; };
		layout(scalar, set = 0, binding = ]] .. slots_binding .. [[) buffer BendSlots { bend_slot bend_slots[]; };
		layout(std430, set = 0, binding = ]] .. counters_binding .. [[) buffer BendCounters { uint bend_counters[]; };

		uint64_t bend_assign(uint pool, float distance_to_camera, in float m[12]) {
			if (pool == 0u) return 0ul;

			bend_pool p = bend_pools[pool];

			if (p.range <= 0.0 || distance_to_camera > p.range) return 0ul;

			uint k = atomicAdd(bend_counters[pool], 1u);

			if (k >= p.used) return 0ul;

			uint b = p.first_slot + k;

			for (uint c = 0u; c < 12u; c++) {
				bend_slots[b].m[c] = m[c];
			}

			return bend_slots[b].blas;
		}
	]]
end

function vegetation_bend.GetPool(mesh_row, material, polygon, max_copies)
	local by_material = pool_keys[mesh_row]
	local by_polygon = by_material and by_material[material]
	local pool = by_polygon and by_polygon[polygon]

	if pool then return pool end

	local pools, slots = get_tables()
	local mesh = meshes.GetRecord(mesh_row)
	local copies = math.min(
		math.max(math.floor(bend_triangles:Get() / mesh.triangle_count), 1),
		max_copies or math.huge
	)
	pool = {
		id = pools:Alloc(),
		row = mesh_row,
		mesh = mesh,
		trace_row = mesh_row,
		material = material,
		polygon = polygon,
		copies = copies,
		first = slots:AllocRange(copies),
		records = {},
		used = 0,
		refs = 0,
	}
	-- a copy is built before any instance is assigned its slot, and a zero matrix bends it into NaN triangles that stay inactive through every later refit
	local slot_rows = slots:Get()

	for i = pool.first, pool.first + copies - 1 do
		ffi.fill(slot_rows[i].m, ffi.sizeof(slot_rows[i].m))
		slot_rows[i].m[0], slot_rows[i].m[5], slot_rows[i].m[10] = 1, 1, 1
	end

	pool_keys[mesh_row] = by_material or {}
	pool_keys[mesh_row][material] = by_polygon or {}
	pool_keys[mesh_row][material][polygon] = pool
	active[pool] = true
	return pool
end

function vegetation_bend.RefPool(pool)
	pool.refs = pool.refs + 1
end

function vegetation_bend.UnrefPool(pool)
	pool.refs = pool.refs - 1

	if pool.refs > 0 then return end

	for _, record in ipairs(pool.records) do
		vegetation_bend.ReleaseRecord(record)
	end

	local pools, slots = get_tables()
	slots:FreeRange(pool.first, pool.copies)
	pools:Free(pool.id)
	pool_keys[pool.row][pool.material][pool.polygon] = nil
	active[pool] = nil
end

-- sizes every pool from what the gpu counted a few frames ago, makes or remakes the copies it asks for and clears the counters the next assignment adds to
function vegetation_bend.Prepare(cmd)
	if not next(active) then return end

	ensure_counters()
	local pools, slots = get_tables()
	local pool_rows, slot_rows = pools:Get(), slots:Get()
	local frame = system.GetFrameNumber()
	local asked = readback + ((frame + 1) % READBACK_RING) * pools.capacity
	local animating = enabled:Get()

	for pool in pairs(active) do
		local range = animating and vegetation_bend.GetRange(pool.material, pool.polygon) or 0
		local wanted = asked[pool.id]
		pool.used = range > 0 and
			wanted > 0 and
			math.min(pool.copies, wanted + 2 + math.floor(wanted / 4)) or
			0
		local variant = pool.trace_row ~= pool.row and meshes.GetRecord(pool.trace_row)
		local omm = variant and variant.omm.micromap and variant.omm or nil
		local records = pool.records

		for k = 1, #records do
			if records[k].blas_record.omm ~= omm then
				vegetation_bend.ReleaseRecord(records[k])
				records[k] = vegetation_bend.NewRecord(pool.mesh, omm)
			end
		end

		for k = #records + 1, pool.used do
			records[k] = vegetation_bend.NewRecord(pool.mesh, omm)
		end

		for k = 1, #records do
			slot_rows[pool.first + k - 1].blas = records[k].blas_record.address
		end

		local row = pool_rows[pool.id]
		row.first_slot = pool.first
		row.used = pool.used
		row.range = range
	end

	cmd:FillBuffer(counters_buffer, 0, counters_buffer:GetSize(), 0)
	cmd:PipelineBarrier{
		srcStage = {"host", "transfer", "compute", "acceleration_structure_build_khr"},
		dstStage = "compute",
		memoryBarrier = true,
	}
end

-- bends the copies the assignment filled and refits them, and reads the counters back for the sizing a few frames on
function vegetation_bend.Dispatch(cmd)
	if not next(active) then return end

	local _, slots = get_tables()
	local mesh_rows = meshes.GetTable():Get()
	local slots_address = slots:GetAddress()

	for pool in pairs(active) do
		for k = 1, pool.used do
			vegetation_bend.Queue(
				pool.records[k],
				mesh_rows[pool.row].vertex_address,
				slots_address + (pool.first + k - 1) * ffi.sizeof(BendSlot),
				pool.material,
				pool.polygon
			)
		end
	end

	dispatch_queued(cmd)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "transfer", memoryBarrier = true}
	local frame = system.GetFrameNumber()
	local size = get_tables().capacity * 4
	readback_copy[0].srcOffset = 0
	readback_copy[0].dstOffset = (frame % READBACK_RING) * size
	readback_copy[0].size = size
	cmd:CopyBuffer(counters_buffer, readback_buffer, readback_copy, 1)
end

function vegetation_bend.GetStats()
	local count, triangles, micromapped = 0, 0, 0

	for pool in pairs(active) do
		for k = 1, pool.used do
			count = count + 1
			triangles = triangles + pool.mesh.triangle_count

			if pool.records[k].blas_record.omm then micromapped = micromapped + 1 end
		end
	end

	return count, triangles, micromapped
end

return vegetation_bend
