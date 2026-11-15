local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local system = import("goluwa/system.lua")
local pvars = import("goluwa/cli/pvars.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local accel = import("goluwa/render3d/scene/accel.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local bridge = import("goluwa/render3d/scene/bridge.lua")
local vegetation_pushers = import("goluwa/render3d/vegetation_pushers.lua")
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
	help = "meters from the camera within which bending plants are bent in the ray traced scene, farther ones are traced at rest",
}
pvars.EndGroup()
local MAX_JOBS = 4096
local RING = 4
local LOCAL_SIZE = 64
local ROW = 65535
local animation_fields = {}
local animation_glsl = {}

for i, field in ipairs(model_pipeline.GetVertexAnimationBlock()) do
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
			local position, pixel_scale = model_pipeline.GetVertexAnimationView()
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

			]] .. vertex_layout.BuildGlslDefines("BEND_VERTEX") .. [[

			BendAnimation vertex_animation;
			mat4 bend_world;

			]] .. model_pipeline.BuildVertexAnimationGlsl("bend_world", "compute.camera_position.xyz", "compute.pixel_scale") .. [[

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
				uint o = i * BEND_VERTEX_STRIDE;
				vec3 position = vec3(source.v[o + BEND_VERTEX_POSITION], source.v[o + BEND_VERTEX_POSITION + 1u], source.v[o + BEND_VERTEX_POSITION + 2u]);
				vec3 normal = vec3(source.v[o + BEND_VERTEX_NORMAL], source.v[o + BEND_VERTEX_NORMAL + 1u], source.v[o + BEND_VERTEX_NORMAL + 2u]);
				vec4 color = vec4(source.v[o + BEND_VERTEX_COLOR], source.v[o + BEND_VERTEX_COLOR + 1u], source.v[o + BEND_VERTEX_COLOR + 2u], source.v[o + BEND_VERTEX_COLOR + 3u]);
				VegetationChain chain = VegetationChain(
					vec4(source.v[o + BEND_VERTEX_PIVOT], source.v[o + BEND_VERTEX_PIVOT + 1u], source.v[o + BEND_VERTEX_PIVOT + 2u], source.v[o + BEND_VERTEX_PIVOT + 3u]),
					vec3(source.v[o + BEND_VERTEX_CHAIN_MID], source.v[o + BEND_VERTEX_CHAIN_MID + 1u], source.v[o + BEND_VERTEX_CHAIN_MID + 2u]),
					vec3(source.v[o + BEND_VERTEX_CHAIN_TIP], source.v[o + BEND_VERTEX_CHAIN_TIP + 1u], source.v[o + BEND_VERTEX_CHAIN_TIP + 2u])
				);
				mat3 world3 = mat3(bend_world);
				mat3 inverse_world3 = inverse(world3);
				vec3 world_position = (bend_world * vec4(position, 1.0)).xyz;
				vec3 world_normal = normalize(transpose(inverse_world3) * normal);
				position += inverse_world3 * get_vertex_animation_offset(world_position, world_normal, color, chain);
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

function vegetation_bend.GetDistance()
	return max_distance:Get()
end

-- a positions only copy of the mesh that the bend writes and an acceleration structure over it with the mesh's indices
function vegetation_bend.NewRecord(mesh)
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

-- whether a part with this material and polygon moves at all in this frame's wind and pushers
function vegetation_bend.Animates(material, polygon)
	model_pipeline.FillVertexAnimationData(scratch_animation, material, polygon)
	return animates(scratch_animation)
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
	model_pipeline.FillVertexAnimationData(job.animation, material, polygon)
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

-- bends everything queued since the last dispatch and builds or refits their acceleration structures
function vegetation_bend.Dispatch(cmd)
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

local seen = {}

local function produce(cmd)
	local camera = model_pipeline.GetVertexAnimationView()
	local reach = max_distance:Get()
	table.clear(seen)

	if enabled:Get() then
		local data_rows = instances.GetDataTable():Get()
		local mesh_rows = meshes.GetTable():Get()

		for visual in pairs(bridge.GetBendingVisuals()) do
			for _, item in ipairs(visual.scene_instances) do
				local id = item.id
				local data = data_rows[id]
				local dx, dy, dz = camera.x - data.center_x, camera.y - data.center_y, camera.z - data.center_z

				if
					not item.hidden and
					item.material:HasVertexAnimation() and
					math.sqrt(dx * dx + dy * dy + dz * dz) - data.radius <= reach and
					instances.IsLevelShown(id, camera) and
					vegetation_bend.Animates(item.material, item.entry.polygon3d)
				then
					local mesh = meshes.GetRecord(item.mesh_row)
					local record = bent[id]

					if record and (record.item ~= item or record.mesh ~= mesh) then
						vegetation_bend.ReleaseRecord(record)
						record = nil
					end

					if not record then
						record = vegetation_bend.NewRecord(mesh)
						record.item = item
						bent[id] = record
					end

					if
						vegetation_bend.Queue(
							record,
							mesh_rows[item.mesh_row].vertex_address,
							instances.GetTLASRecordAddress(id),
							item.material,
							item.entry.polygon3d
						)
					then
						seen[id] = true
					end
				end
			end
		end
	end

	for id, record in pairs(bent) do
		if not seen[id] then
			instances.SetBLASOverride(id, 0)
			vegetation_bend.ReleaseRecord(record)
			bent[id] = nil
		end
	end

	vegetation_bend.Dispatch(cmd)

	for id, record in pairs(bent) do
		instances.SetBLASOverride(id, record.blas_record.address)
	end
end

function vegetation_bend.GetStats()
	local count, triangles = 0, 0

	for _, record in pairs(bent) do
		count = count + 1
		triangles = triangles + record.mesh.triangle_count
	end

	return count, triangles
end

if render.GetDevice().ray_tracing_supported then
	instances.AddProducer("vegetation_bend", produce)
end

return vegetation_bend
