local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local system = import("goluwa/system.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local skinning = library()
skinning.MAX_JOBS = 4096
skinning.MAX_MATRIX_FLOATS = 12 * 65536
skinning.RING = 4
skinning.MOTION_MARK = -1000000
skinning.MOTION_THRESHOLD = -500000
local LOCAL_SIZE = 64
local ROW = 65535
local Job = ffi.typeof([[struct {
	uint32_t bind[2];
	uint32_t destination[2];
	uint32_t bones[2];
	uint32_t matrices[2];
	uint32_t morph_ranges[2];
	uint32_t morph_entries[2];
	uint32_t morph_weights[2];
	uint32_t count;
	uint32_t group_start;
}]])
local JobPtr = ffi.typeof("$ *", Job)
local uint64_ptr = ffi.typeof("uint64_t *")
local FloatPtr = ffi.typeof("float *")
local queue = {}
local queued_count = 0
local buffers = nil
local pipeline = nil
local job_base = 0
local job_count = 0
local group_count = 0

local function get_buffers()
	if buffers then return buffers end

	buffers = {
		jobs = render.CreateBuffer{
			byte_size = ffi.sizeof(Job) * skinning.MAX_JOBS * skinning.RING,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "skinning jobs",
		},
		matrices = render.CreateBuffer{
			byte_size = skinning.MAX_MATRIX_FLOATS * 4 * skinning.RING,
			buffer_usage = {"storage_buffer", "shader_device_address"},
			memory_property = {"host_visible", "host_coherent"},
			label = "skinning matrices",
		},
	}
	buffers.job_data = ffi.cast(JobPtr, buffers.jobs:Map())
	buffers.matrix_data = ffi.cast(FloatPtr, buffers.matrices:Map())
	buffers.matrix_address = buffers.matrices:GetDeviceAddress()
	return buffers
end

local function get_pipeline()
	if pipeline then return pipeline end

	pipeline = EasyPipeline.Compute{
		name = "skinning",
		DescriptorSetCount = 1,
		LocalSize = {x = LOCAL_SIZE, y = 1, z = 1},
		descriptor_sets = {
			{
				type = "storage_buffer",
				binding_index = 0,
				stageFlags = "compute",
				set_index = 0,
				args = function()
					local jobs = get_buffers().jobs
					return {jobs, jobs.size}
				end,
			},
		},
		block = {{"job_base", "int"}, {"job_count", "int"}, {"group_count", "int"}},
		write = function(self, block)
			block.job_base = job_base
			block.job_count = job_count
			block.group_count = group_count
			return block
		end,
		shader = [[
			layout(buffer_reference, scalar) readonly buffer SkinBind { float v[]; };
			layout(buffer_reference, scalar) buffer SkinDestination { float v[]; };
			struct SkinBone {
				uint indices;
				float w0;
				float w1;
				float w2;
			};
			layout(buffer_reference, scalar) readonly buffer SkinBones { SkinBone b[]; };
			layout(buffer_reference, scalar) readonly buffer SkinMatrices { float m[]; };
			// the morph entries of a vertex are the ones from range.x to range.x + range.y. a weight is picked between the two
			// weights of the flex by the side of the vertex
			layout(buffer_reference, scalar) readonly buffer MorphRanges { uvec2 r[]; };
			struct MorphEntry {
				vec3 delta;
				vec3 normal_delta;
				uint entry_side;
			};
			layout(buffer_reference, scalar) readonly buffer MorphEntries { MorphEntry e[]; };
			layout(buffer_reference, scalar) readonly buffer MorphWeights { float w[]; };
			struct SkinJob {
				uvec2 bind;
				uvec2 destination;
				uvec2 bones;
				uvec2 matrices;
				uvec2 morph_ranges;
				uvec2 morph_entries;
				uvec2 morph_weights;
				uint count;
				uint group_start;
			};
			layout(scalar, set = 0, binding = 0) readonly buffer SkinJobs {
				SkinJob jobs[];
			};

			// polygon_3d's vertex: position 0, normal 3, uv 6, tangent 8, blend 12, color 13
			#define SKIN_VERTEX_FLOATS 17u

			mat4x3 skin_matrix(SkinMatrices matrices, uint bone) {
				uint o = bone * 12u;
				return transpose(mat3x4(
					matrices.m[o], matrices.m[o + 1u], matrices.m[o + 2u], matrices.m[o + 3u],
					matrices.m[o + 4u], matrices.m[o + 5u], matrices.m[o + 6u], matrices.m[o + 7u],
					matrices.m[o + 8u], matrices.m[o + 9u], matrices.m[o + 10u], matrices.m[o + 11u]
				));
			}

			void main() {
				uint flat_group = gl_WorkGroupID.y * ]] .. ROW .. [[u + gl_WorkGroupID.x;

				if (flat_group >= uint(compute.group_count)) return;

				// the last job that starts at or before this workgroup
				uint low = 0u;
				uint high = uint(compute.job_count);

				while (high - low > 1u) {
					uint middle = (low + high) / 2u;

					if (jobs[uint(compute.job_base) + middle].group_start <= flat_group) low = middle; else high = middle;
				}

				SkinJob job = jobs[uint(compute.job_base) + low];
				uint i = (flat_group - job.group_start) * ]] .. LOCAL_SIZE .. [[u + gl_LocalInvocationID.x;

				if (i >= job.count) return;

				SkinBind bind = SkinBind(packUint2x32(job.bind));
				SkinDestination destination = SkinDestination(packUint2x32(job.destination));
				SkinBone bone = SkinBones(packUint2x32(job.bones)).b[i];
				SkinMatrices matrices = SkinMatrices(packUint2x32(job.matrices));
				mat4x3 m = skin_matrix(matrices, bone.indices & 0xFFu) * bone.w0;

				if (bone.w0 < 0.9999) {
					if (bone.w1 > 0.0) m += skin_matrix(matrices, (bone.indices >> 8u) & 0xFFu) * bone.w1;
					if (bone.w2 > 0.0) m += skin_matrix(matrices, (bone.indices >> 16u) & 0xFFu) * bone.w2;
				}

				uint o = i * SKIN_VERTEX_FLOATS;
				vec3 position = vec3(bind.v[o], bind.v[o + 1u], bind.v[o + 2u]);
				vec3 normal = vec3(bind.v[o + 3u], bind.v[o + 4u], bind.v[o + 5u]);
				vec3 tangent = vec3(bind.v[o + 8u], bind.v[o + 9u], bind.v[o + 10u]);

				if (job.morph_ranges.x != 0u || job.morph_ranges.y != 0u) {
					uvec2 range = MorphRanges(packUint2x32(job.morph_ranges)).r[i];
					MorphEntries entries = MorphEntries(packUint2x32(job.morph_entries));
					MorphWeights weights = MorphWeights(packUint2x32(job.morph_weights));

					for (uint k = range.x; k < range.x + range.y; k++) {
						MorphEntry entry = entries.e[k];
						uint index = entry.entry_side >> 8u;
						float w1 = weights.w[index * 2u];
						float w2 = weights.w[index * 2u + 1u];
						float w = w1 + (w2 - w1) * float(entry.entry_side & 255u) / 255.0;
						position += entry.delta * w;
						normal += entry.normal_delta * w;
					}
				}

				// the position this vertex had when the pass last ran, if it ran on it before
				vec3 previous = position;
				bool had_previous = destination.v[o + 16u] < ]] .. skinning.MOTION_THRESHOLD .. [[.0;
				position = m * vec4(position, 1.0);

				if (had_previous) {
					previous = vec3(destination.v[o], destination.v[o + 1u], destination.v[o + 2u]);
				} else {
					previous = position;
				}

				normal = normalize(mat3(m) * normal + 1e-20);
				tangent = normalize(mat3(m) * tangent + 1e-20);
				destination.v[o] = position.x;
				destination.v[o + 1u] = position.y;
				destination.v[o + 2u] = position.z;
				destination.v[o + 3u] = normal.x;
				destination.v[o + 4u] = normal.y;
				destination.v[o + 5u] = normal.z;
				destination.v[o + 8u] = tangent.x;
				destination.v[o + 9u] = tangent.y;
				destination.v[o + 10u] = tangent.z;
				vec3 motion = position - previous;
				destination.v[o + 13u] = motion.x;
				destination.v[o + 14u] = motion.y;
				destination.v[o + 15u] = motion.z;
				destination.v[o + 16u] = ]] .. skinning.MOTION_MARK .. [[.0;
			}
		]],
	}
	return pipeline
end

function skinning.GetBoneBuffer(skin, vertex_count)
	if skin.GpuBuffer then return skin.GpuBuffer end

	local data = ffi.new("uint32_t[?]", vertex_count * 4)
	local floats = ffi.cast(FloatPtr, data)
	local indices, weights = skin.BoneIndices, skin.BoneWeights

	for i = 0, vertex_count - 1 do
		local s = i * 4
		data[s] = bit.bor(
			indices[s],
			bit.lshift(indices[s + 1], 8),
			bit.lshift(indices[s + 2], 16),
			bit.lshift(indices[s + 3], 24)
		)
		floats[s + 1] = weights[s]
		floats[s + 2] = weights[s + 1]
		floats[s + 3] = weights[s + 2]
	end

	skin.GpuBuffer = render.CreateBuffer{
		byte_size = vertex_count * 16,
		buffer_usage = {"storage_buffer", "shader_device_address"},
		memory_property = {"host_visible", "host_coherent"},
		data = data,
		label = "skin bones",
	}
	return skin.GpuBuffer
end

function skinning.GetMorphData(skin, vertex_count)
	if skin.GpuMorph ~= nil then return skin.GpuMorph end

	local flexes = skin.Flexes

	if not (flexes and flexes[1]) then
		skin.GpuMorph = false
		return false
	end

	local counts = ffi.new("uint32_t[?]", vertex_count)
	local total = 0

	for _, flex in ipairs(flexes) do
		for k = 0, flex.Count - 1 do
			local vertex = flex.Indices[k]

			if vertex < vertex_count then
				counts[vertex] = counts[vertex] + 1
				total = total + 1
			end
		end
	end

	local ranges = ffi.new("uint32_t[?]", vertex_count * 2)
	local cursors = ffi.new("uint32_t[?]", vertex_count)
	local first = 0

	for i = 0, vertex_count - 1 do
		ranges[i * 2] = first
		ranges[i * 2 + 1] = counts[i]
		cursors[i] = first
		first = first + counts[i]
	end

	local entries = ffi.new("float[?]", total * 7)
	local entry_words = ffi.cast("uint32_t *", entries)

	for entry_index, flex in ipairs(flexes) do
		for k = 0, flex.Count - 1 do
			local vertex = flex.Indices[k]

			if vertex < vertex_count then
				local o = cursors[vertex] * 7
				cursors[vertex] = cursors[vertex] + 1

				for c = 0, 5 do
					entries[o + c] = flex.Deltas[k * 6 + c]
				end

				entry_words[o + 6] = bit.bor(bit.lshift(entry_index - 1, 8), flex.Sides[k])
			end
		end
	end

	local ranges_buffer = render.CreateBuffer{
		byte_size = vertex_count * 8,
		buffer_usage = {"storage_buffer", "shader_device_address"},
		memory_property = {"host_visible", "host_coherent"},
		data = ranges,
		label = "skin morph ranges",
	}
	local entries_buffer = render.CreateBuffer{
		byte_size = total * 28,
		buffer_usage = {"storage_buffer", "shader_device_address"},
		memory_property = {"host_visible", "host_coherent"},
		data = entries,
		label = "skin morph entries",
	}
	skin.GpuMorph = {
		ranges = ranges_buffer,
		entries = entries_buffer,
		ranges_address = ranges_buffer:GetDeviceAddress(),
		entries_address = entries_buffer:GetDeviceAddress(),
		entry_count = #flexes,
	}
	return skin.GpuMorph
end

function skinning.Queue(rig)
	queued_count = queued_count + 1
	queue[queued_count] = rig
end

function skinning.Dispatch(cmd)
	if queued_count == 0 then return end

	local b = get_buffers()
	local ring = system.GetFrameNumber() % skinning.RING
	job_base = ring * skinning.MAX_JOBS
	local matrix_offset = ring * skinning.MAX_MATRIX_FLOATS
	local jobs = 0
	local floats = 0
	local groups = 0

	for i = 1, queued_count do
		local rig = queue[i]
		queue[i] = nil

		if rig.removed then goto continue end

		local matrix_count = rig.skeleton.BoneCount * 12
		local weight_count = rig.morph_weight_count

		if
			floats + matrix_count + weight_count > skinning.MAX_MATRIX_FLOATS or
			jobs + #rig.skinned > skinning.MAX_JOBS
		then
			if not skinning.warned then
				skinning.warned = true
				llog(
					"skinning is full (%d jobs, %d bone matrices), the rest of the animated models are not skinned",
					jobs,
					floats / 12
				)
			end
		else
			ffi.copy(b.matrix_data + matrix_offset + floats, rig.matrices, matrix_count * 4)
			local matrix_address = b.matrix_address + (matrix_offset + floats) * 4
			local weights_address = b.matrix_address + (matrix_offset + floats + matrix_count) * 4

			if weight_count > 0 then
				ffi.copy(
					b.matrix_data + matrix_offset + floats + matrix_count,
					rig.morph_weights,
					weight_count * 4
				)
			end

			for _, skinned in ipairs(rig.skinned) do
				local job = b.job_data[job_base + jobs]
				ffi.cast(uint64_ptr, job.bind)[0] = skinned.bind_address
				ffi.cast(uint64_ptr, job.destination)[0] = skinned.destination_address
				ffi.cast(uint64_ptr, job.bones)[0] = skinned.bones_address
				ffi.cast(uint64_ptr, job.matrices)[0] = matrix_address

				if skinned.morph_active then
					ffi.cast(uint64_ptr, job.morph_ranges)[0] = skinned.morph.ranges_address
					ffi.cast(uint64_ptr, job.morph_entries)[0] = skinned.morph.entries_address
					ffi.cast(uint64_ptr, job.morph_weights)[0] = weights_address + skinned.weight_offset * 4
				else
					ffi.cast(uint64_ptr, job.morph_ranges)[0] = 0
				end

				job.count = skinned.count
				job.group_start = groups
				groups = groups + math.ceil(skinned.count / LOCAL_SIZE)
				jobs = jobs + 1
			end

			floats = floats + matrix_count + weight_count
		end

		::continue::
	end

	queued_count = 0

	if jobs == 0 then return end

	cmd:PipelineBarrier{srcStage = "all_commands", dstStage = "compute", memoryBarrier = true}
	job_count = jobs
	group_count = groups
	gpu_timing.BeginScope(cmd, "skinning")
	get_pipeline():Dispatch(cmd, math.min(groups, ROW), math.ceil(groups / ROW), 1, 1)
	gpu_timing.EndScope(cmd, "skinning")
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "all_commands", memoryBarrier = true}
end

return skinning
