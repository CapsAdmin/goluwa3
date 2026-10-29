local ffi = require("ffi")
local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local hit = import("goluwa/render3d/scene/hit.lua")
local rt = import("goluwa/render3d/scene/rt.lua")
local materials = import("goluwa/render3d/scene/materials.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local acoustics = import("goluwa/audio/acoustics.lua")
local acoustics_gpu = {}
local MAX_SOURCES = 8
local MAX_QUERIES = 2048
local MAX_RAYS = 4096
local MAX_SAMPLES = 512
local MAX_MATERIALS = 8192
local GROUP_SIZE = 64
local ACC = 17 + 9 * MAX_SOURCES
local SAMPLE_FLOATS = 11
local BINDING_UNIFORM = 0
local BINDING_QUERIES = 1
local BINDING_OUTPUT = 2
local BINDING_MATERIALS = 3
local BINDING_TLAS = 4
local BINDING_HIT = 5
local MAX_GROUPS = MAX_RAYS / GROUP_SIZE
local QUERY_FLOATS = acoustics.QUERY_FLOATS
local OUTPUT_FLOATS = MAX_GROUPS * ACC + MAX_SAMPLES * SAMPLE_FLOATS + MAX_QUERIES * QUERY_FLOATS
local float_ptr = ffi.typeof("float *")

local function build_pipeline(slots)
	return EasyPipeline.Compute{
		name = "audio_acoustics_trace",
		DescriptorSetCount = slots,
		LocalSize = {x = GROUP_SIZE, y = 1, z = 1},
		storage_buffers = {
			{binding_index = BINDING_QUERIES},
			{binding_index = BINDING_OUTPUT},
			{binding_index = BINDING_MATERIALS},
		},
		descriptor_sets = hit.GetDescriptorSets(BINDING_HIT, "compute", BINDING_TLAS),
		uniform_buffers = {
			{
				name = "acoustic",
				binding_index = BINDING_UNIFORM,
				block = {
					{"listener", "vec4"},
					{"rotation", "vec4", 3},
					{"sources", "vec4", MAX_SOURCES},
					{"air", "vec4"},
					{"timing", "vec4"},
					{"params", "vec4"},
					{"counts", "ivec4"},
					{"extra", "ivec4"},
				},
				write = function(self, block)
					local job = acoustics_gpu.current_job
					local tracer = acoustics_gpu.current_tracer
					local l = job.listener
					block.listener[0], block.listener[1], block.listener[2], block.listener[3] = l.x, l.y, l.z, acoustics.LISTENER_CLEARANCE
					local m = job.rotation

					for row = 0, 2 do
						block.rotation[row][0] = m[row * 3 + 1]
						block.rotation[row][1] = m[row * 3 + 2]
						block.rotation[row][2] = m[row * 3 + 3]
						block.rotation[row][3] = 0
					end

					for i = 0, MAX_SOURCES - 1 do
						local source = job.sources[i + 1]

						if source then
							block.sources[i][0], block.sources[i][1], block.sources[i][2] = source.x, source.y, source.z
							block.sources[i][3] = job.direct_time[i + 1]
						end
					end

					for b = 0, 2 do
						block.air[b] = acoustics.AirEnergyPerMeter(b + 1)
					end

					block.air[3] = acoustics.SURFACE_OFFSET
					block.timing[0] = job.split_time
					block.params[0] = job.speed
					block.params[1] = acoustics.OPEN_DISTANCE
					block.params[2] = acoustics.SOURCE_CLEARANCE
					block.params[3] = acoustics.TRACE_DISTANCE
					block.counts[0] = job.rays
					block.counts[1] = job.bounces
					block.counts[2] = math.min(job.sample_count, job.rays)
					block.counts[3] = #job.sources
					block.extra[0] = job.query_count
					block.extra[1] = job.seed
					block.extra[2] = tracer.material_count
					block.extra[3] = 0
					return block
				end,
			},
		},
		custom_declarations = hit.GetSceneGLSL("acoustic_scene", BINDING_TLAS) .. hit.GetGLSL(BINDING_HIT) .. (
				[[
			layout(set = 0, binding = %d) readonly buffer AcousticQueries { vec4 queries[]; };
			layout(set = 0, binding = %d) buffer AcousticOutput { float result[]; };
			layout(set = 0, binding = %d) readonly buffer AcousticMaterials { vec4 absorptions[]; };
		]]
			):format(BINDING_QUERIES, BINDING_OUTPUT, BINDING_MATERIALS),
		shader = hit.GetTraceGLSL("acoustic_scene") .. (
				[[
			#define ACC %d
			#define GROUP_SIZE %d
			#define MAX_GROUPS %d
			#define SAMPLE_FLOATS %d
			#define MAX_SAMPLES %d
			#define QUERY_FLOATS %d
			#define DEFAULT_ABSORPTION vec3(%f, %f, %f)

			shared float reduce_buffer[GROUP_SIZE];

			uint acoustic_hash(uint x) {
				x ^= x >> 16u;
				x *= 0x7feb352du;
				x ^= x >> 15u;
				x *= 0x846ca68bu;
				x ^= x >> 16u;
				return x;
			}

			float acoustic_random(inout uint state) {
				state = acoustic_hash(state);
				return float(state >> 8u) / 16777216.0;
			}

			vec3 acoustic_cosine(vec3 n, float u1, float u2) {
				float r = sqrt(u1);
				float phi = 6.283185307 * u2;
				vec3 t = abs(n.x) > 0.5 ? vec3(-n.y, n.x, 0.0) : vec3(0.0, -n.z, n.y);
				t = normalize(t);
				vec3 b = cross(n, t);
				return t * (r * cos(phi)) + b * (r * sin(phi)) + n * sqrt(max(0.0, 1.0 - u1));
			}

			vec3 acoustic_absorption(uint instance) {
				uint row = scene_instance_material(instance);

				if (row >= uint(acoustic.extra.z)) return DEFAULT_ABSORPTION;

				return absorptions[row].xyz;
			}

			void main() {
				uint id = gl_GlobalInvocationID.x;
				uint lid = gl_LocalInvocationID.x;
				int ray_count = acoustic.counts.x;
				uint ray_groups = uint((ray_count + GROUP_SIZE - 1) / GROUP_SIZE);
				uint sample_base = uint(MAX_GROUPS * ACC);
				uint query_base = sample_base + uint(MAX_SAMPLES * SAMPLE_FLOATS);
				scene_trace_hit hit;

				if (gl_WorkGroupID.x >= ray_groups) {
					uint q = id - ray_groups * uint(GROUP_SIZE);

					if (q >= uint(acoustic.extra.x)) return;

					vec4 a = queries[q * 2u];
					vec4 b = queries[q * 2u + 1u];
					vec4 r = vec4(-1.0, 0.0, 0.0, 0.0);
					vec3 absorption = vec3(0.0);

					if (b.w > a.w && scene_trace(a.xyz, b.xyz, a.w, b.w, hit)) {
						r = vec4(hit.distance, hit.normal);
						absorption = acoustic_absorption(hit.instance);
					}

					uint at = query_base + q * uint(QUERY_FLOATS);
					result[at] = r.x;
					result[at + 1u] = r.y;
					result[at + 2u] = r.z;
					result[at + 3u] = r.w;
					result[at + 4u] = absorption.x;
					result[at + 5u] = absorption.y;
					result[at + 6u] = absorption.z;
					result[at + 7u] = 0.0;
					return;
				}

				float acc[ACC];

				for (int i = 0; i < ACC; i++) acc[i] = 0.0;

				if (int(id) < ray_count) {
					float speed = acoustic.params.x;
					float open_distance = acoustic.params.y;
					float clearance = acoustic.params.z;
					float trace_distance = acoustic.params.w;
					float offset = acoustic.air.w;
					vec3 air = acoustic.air.xyz;
					int source_count = acoustic.counts.w;
					float z = 1.0 - 2.0 * (float(id) + 0.5) / float(ray_count);
					float rr = sqrt(max(0.0, 1.0 - z * z));
					float phi = float(id) * 2.399963229728653;
					vec3 local_dir = vec3(cos(phi) * rr, sin(phi) * rr, z);
					vec3 dir = vec3(dot(acoustic.rotation[0].xyz, local_dir), dot(acoustic.rotation[1].xyz, local_dir), dot(acoustic.rotation[2].xyz, local_dir));
					vec3 origin = acoustic.listener.xyz;
					float tmin = acoustic.listener.w;
					float path_length = 0.0;
					vec3 w = vec3(1.0);
					bool escaped = false;
					uint rng = acoustic_hash(id * 9781u + uint(acoustic.extra.y));
					acc[0] = 1.0;

					for (int bounce = 0; bounce < acoustic.counts.y; bounce++) {
						bool found = scene_trace(origin, dir, tmin, trace_distance, hit);
						float distance = found ? hit.distance : -1.0;
						vec3 absorption = found ? acoustic_absorption(hit.instance) : vec3(0.0);

						if (bounce == 0) {
							float d = found ? min(distance, open_distance) : open_distance;
							acc[4] += 4.18879020479 * d * d * d;

							if (found && int(id) < acoustic.counts.z) {
								uint s = sample_base + id * uint(SAMPLE_FLOATS);
								vec3 p = origin + dir * distance;
								result[s] = p.x;
								result[s + 1u] = p.y;
								result[s + 2u] = p.z;
								result[s + 3u] = hit.normal.x;
								result[s + 4u] = hit.normal.y;
								result[s + 5u] = hit.normal.z;
								result[s + 6u] = distance;
								result[s + 7u] = abs(dot(hit.normal, dir));
								result[s + 8u] = absorption.x;
								result[s + 9u] = absorption.y;
								result[s + 10u] = absorption.z;
							} else if (int(id) < acoustic.counts.z) {
								result[sample_base + id * uint(SAMPLE_FLOATS) + 6u] = -1.0;
							}
						}

						if (!found || distance > open_distance) {
							acc[2] += 1.0;
							escaped = true;
							break;
						}

						acc[1] += 1.0;
						acc[3] += distance;
						path_length += distance;
						vec3 n = hit.normal;
						vec3 p = origin + dir * distance + n * offset;

						bool settled = bounce >= acoustic.counts.y / 2;

						if (settled) {
							acc[8] += w.x;
							acc[9] += w.y;
							acc[10] += w.z;
						}

						vec3 reflect = vec3(1.0) - absorption;
						vec3 log_reflect = log(max(reflect, vec3(1e-6)));
						acc[5] += log_reflect.x;
						acc[6] += log_reflect.y;
						acc[7] += log_reflect.z;

						for (int s = 0; s < source_count; s++) {
							vec4 source = acoustic.sources[s];
							vec3 to_source = source.xyz - p;
							float d2 = dot(to_source, to_source);
							float d = sqrt(d2);
							float cos_s = dot(to_source, n) / max(d, 1e-6);

							if (cos_s > 0.0 && d > clearance && !scene_occluded(p, to_source / d, 0.0, d - clearance)) {
								float total = path_length + d;
								float t = total / speed - source.w;
								vec3 e = (4.0 * cos_s / max(d2, 0.01)) * w * reflect * exp(-air * total);
								int base = 17 + s * 9;

								if (settled) {
									acc[base] += e.x;
									acc[base + 1] += e.y;
									acc[base + 2] += e.z;
								}

								if (bounce > 0 && t > acoustic.timing.x) {
									acc[base + 3] += e.x;
									acc[base + 4] += e.y;
									acc[base + 5] += e.z;
									acc[base + 6] += e.x * t;
									acc[base + 7] += e.y * t;
									acc[base + 8] += e.z * t;
								}
							}
						}

						w *= reflect;
						origin = p;
						tmin = 0.0;
						float u1 = acoustic_random(rng);
						float u2 = acoustic_random(rng);
						dir = acoustic_cosine(n, u1, u2);
					}

					if (!escaped) {
						acc[11] += w.x;
						acc[12] += w.y;
						acc[13] += w.z;
						acc[14] += w.x * path_length;
						acc[15] += w.y * path_length;
						acc[16] += w.z * path_length;
					}
				}

				for (int f = 0; f < ACC; f++) {
					reduce_buffer[lid] = acc[f];
					barrier();

					for (uint stride = uint(GROUP_SIZE) / 2u; stride > 0u; stride >>= 1u) {
						if (lid < stride) reduce_buffer[lid] += reduce_buffer[lid + stride];
						barrier();
					}

					if (lid == 0u) result[gl_WorkGroupID.x * uint(ACC) + uint(f)] = reduce_buffer[0];
					barrier();
				}
			}
		]]
			):format(
				ACC,
				GROUP_SIZE,
				MAX_GROUPS,
				SAMPLE_FLOATS,
				MAX_SAMPLES,
				QUERY_FLOATS,
				acoustics.DEFAULT_ABSORPTION[1],
				acoustics.DEFAULT_ABSORPTION[2],
				acoustics.DEFAULT_ABSORPTION[3]
			),
	}
end

local META = {}
META.__index = META

function META:IsReady()
	return true
end

function META:Submit(job)
	self.pending = job
end

function META:Collect()
	local done = self.done

	if #done == 0 then return done end

	self.done = {}
	return done
end

function META:Probe(listener, source, speed)
	if self.cpu then return self.cpu:Probe(listener, source, speed) end
end

function META:GetSlot(index)
	local slot = self.slots[index]

	if slot then return slot end

	slot = {
		queries = render.CreateBuffer{
			byte_size = MAX_QUERIES * 32,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "audio_acoustics queries",
		},
		output = render.CreateBuffer{
			byte_size = OUTPUT_FLOATS * 4,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent", "host_cached"},
			label = "audio_acoustics output",
		},
		materials = render.CreateBuffer{
			byte_size = MAX_MATERIALS * 16,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "audio_acoustics materials",
		},
	}
	self.slots[index] = slot
	return slot
end

function META:UploadMaterials(slot)
	local count = math.min(#materials.list, MAX_MATERIALS)
	local out = ffi.cast(float_ptr, slot.materials:Map())

	for i = 0, count - 1 do
		local a = materials.list[i + 1]:GetAcousticAbsorption()
		out[i * 4], out[i * 4 + 1], out[i * 4 + 2], out[i * 4 + 3] = a.x, a.y, a.z, 0
	end

	self.material_count = count
end

function META:ReadResult(job, slot)
	local out = ffi.cast(float_ptr, slot.output:Map())
	local result = acoustics.NewResult(job)
	local stats = result.stats
	local groups = math.ceil(job.rays / GROUP_SIZE)

	for g = 0, groups - 1 do
		local at = g * ACC
		stats.rays = stats.rays + out[at]
		stats.hits = stats.hits + out[at + 1]
		stats.escapes = stats.escapes + out[at + 2]
		stats.segment = stats.segment + out[at + 3]
		stats.volume = stats.volume + out[at + 4]

		for b = 1, 3 do
			stats.log_reflect[b] = stats.log_reflect[b] + out[at + 4 + b]
			stats.settled_throughput[b] = stats.settled_throughput[b] + out[at + 7 + b]
			stats.last_throughput[b] = stats.last_throughput[b] + out[at + 10 + b]
			stats.last_throughput_length[b] = stats.last_throughput_length[b] + out[at + 13 + b]
		end

		for s = 1, #job.sources do
			local sums = result.sources[s]
			local base = at + 17 + (s - 1) * 9

			for b = 1, 3 do
				sums.settled[b] = sums.settled[b] + out[base + b - 1]
				sums.late[b] = sums.late[b] + out[base + 2 + b]
				sums.moment[b] = sums.moment[b] + out[base + 5 + b]
			end
		end
	end

	local samples = result.samples
	local sample_base = MAX_GROUPS * ACC

	for i = 0, math.min(job.sample_count, job.rays) - 1 do
		local at = sample_base + i * SAMPLE_FLOATS

		if out[at + 6] > 0 then
			for k = 0, SAMPLE_FLOATS - 1 do
				samples[#samples + 1] = out[at + k]
			end
		end
	end

	local queries = result.queries
	local query_base = sample_base + MAX_SAMPLES * SAMPLE_FLOATS

	for i = 0, job.query_count * QUERY_FLOATS - 1 do
		queries[i + 1] = out[query_base + i]
	end

	return result
end

function META:Dispatch(cmd)
	local index = render.GetCurrentFrame() or 1
	local slot = self:GetSlot(index)
	local inflight = self.inflight[index]

	if inflight then
		self.inflight[index] = nil
		self.done[#self.done + 1] = {job = inflight, result = self:ReadResult(inflight, slot)}
	end

	local job = self.pending

	if not job then return end

	self.pending = nil
	job.rays = math.min(job.rays, MAX_RAYS)
	job.sample_count = math.min(job.sample_count, MAX_SAMPLES)
	job.query_count = math.min(job.query_count, MAX_QUERIES)

	for i = #job.sources, MAX_SOURCES + 1, -1 do
		job.sources[i] = nil
		job.sounds[i] = nil
	end

	local q = ffi.cast(float_ptr, slot.queries:Map())

	for i = 0, job.query_count * 8 - 1 do
		q[i] = job.queries[i + 1]
	end

	self:UploadMaterials(slot)
	local tlas = rt.GetTLAS(cmd)
	local pipeline = self.pipeline
	pipeline:UpdateDescriptorSet("storage_buffer", index, BINDING_QUERIES, 0, slot.queries, slot.queries:GetSize())
	pipeline:UpdateDescriptorSet("storage_buffer", index, BINDING_OUTPUT, 0, slot.output, slot.output:GetSize())
	pipeline:UpdateDescriptorSet(
		"storage_buffer",
		index,
		BINDING_MATERIALS,
		0,
		slot.materials,
		slot.materials:GetSize()
	)
	pipeline:UpdateDescriptorSet("acceleration_structure_khr", index, BINDING_TLAS, 0, tlas)
	hit.Bind(pipeline, index, BINDING_HIT)
	acoustics_gpu.current_job = job
	acoustics_gpu.current_tracer = self
	pipeline:UploadConstants()
	cmd:PipelineBarrier{
		srcStage = {"acceleration_structure_build_khr", "host"},
		dstStage = "compute",
		memoryBarrier = true,
	}
	gpu_timing.BeginScope(cmd, "audio_acoustics")
	pipeline.pipeline:Dispatch(
		cmd,
		math.ceil(job.rays / GROUP_SIZE) + math.ceil(job.query_count / GROUP_SIZE),
		1,
		1,
		index,
		pipeline.dynamic_offsets
	)
	gpu_timing.EndScope(cmd, "audio_acoustics")
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "host", memoryBarrier = true}
	self.inflight[index] = job
end

function META:Remove()
	event.RemoveListener("PreRenderPass", self.listener_id)
end

function acoustics_gpu.New(budget)
	local self = setmetatable(
		{
			done = {},
			slots = {},
			inflight = {},
			material_count = 0,
			budget = budget or
				{
					rays = 1024,
					bounces = 8,
					samples = 256,
					sources = MAX_SOURCES - 1,
					fresnel = 4,
					reflection_sources = MAX_SOURCES - 1,
				},
		},
		META
	)
	self.pipeline = build_pipeline(math.max(render.GetSwapchainImageCount() or 1, 1))

	if PHYSICS then self.cpu = import("goluwa/audio/acoustics_cpu.lua").New() end

	self.listener_id = "audio_acoustics_gpu_" .. tostring(self)

	event.AddListener(
		"PreRenderPass",
		self.listener_id,
		function()
			self:Dispatch(render.GetCommandBuffer())
		end,
		{priority = -10}
	)

	return self
end

return acoustics_gpu
