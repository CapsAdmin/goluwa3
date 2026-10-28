local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local bridge = import("goluwa/render3d/scene/bridge.lua")
local materials = import("goluwa/render3d/scene/materials.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local hit = import("goluwa/render3d/scene/hit.lua")
local store = import("goluwa/render3d/scene/store.lua")
local pvars = import("goluwa/cli/pvars.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local emitters = {}
pvars.StartGroup("Lighting", "Emitters", {store = false, prefix = "gi_"})
local enabled = pvars.Setup2{
	key = "gi_emitters",
	default = true,
	help = "emissive surfaces light the gi (probes, surfels, fog and particles) through emitter samples, off is for telling whether they cause noise",
}
local additive = pvars.Setup2{
	key = "gi_additive_emitters",
	default = false,
	help = "additive materials light the gi like emissive surfaces do",
}
pvars.EndGroup()
emitters.DOUBLE_SIDED = 0x80000000
local EMITTER_WORDS = 4
local HEADER_WORDS = 4
local SOURCE_WORDS = 8
emitters.LOCAL_SOURCES = 512
local SCAN_SIZE = 256
emitters.EMITTER_WORDS = EMITTER_WORDS
local list = {count = 0, version = -1}
local Source = ffi.typeof([[struct {
	uint32_t first;
	uint32_t instance;
	uint32_t triangle_count;
	uint32_t flags;
	float luminance;
}]])
local SourceArray = ffi.typeof("$[?]", Source)
local sources_buffer
local words_buffer
local sums_base = 0
local built_frame = -1

function emitters.Get(include_additive)
	if list.version == bridge.emitter_version and list.additive == include_additive then
		return list
	end

	local sources = {}
	local count = 0
	local total = 0

	for visual in pairs(bridge.GetEmissiveVisuals()) do
		if visual.Visible then
			for _, item in ipairs(visual.scene_instances) do
				local material = item.material
				local r, g, b = materials.GetEmissive(material)
				local luminance = item.level == 0 and 0.2126 * r + 0.7152 * g + 0.0722 * b or 0
				local additive = material:GetAdditive() and
					not material:GetAlbedoAlphaIsEmissive()
					and
					material:GetEmissiveTexture() == nil

				if luminance > 0 and (include_additive or not additive) then
					count = count + 1
					sources[count] = {
						first = total,
						instance = item.id,
						triangle_count = meshes.GetRecord(item.mesh_row).triangle_count,
						flags = material:GetDoubleSided() and emitters.DOUBLE_SIDED or 0,
						luminance = luminance,
					}
					total = total + sources[count].triangle_count
				end
			end
		end
	end

	list.source_count = count
	list.count = total
	list.additive = include_additive
	list.version = bridge.emitter_version
	list.sources_version = (list.sources_version or 0) + 1
	list.sources = sources
	return list
end

do
	local pipelines
	local uniform = {
		source_count = 0,
		triangle_count = 0,
		block_count = 0,
		sums_base = 0,
		source_base = 0,
	}
	local bound = {}
	local uploaded_version = -1

	local function create_pipelines()
		local slots = math.max(render.GetSwapchainImageCount() or 1, 1)
		local declarations = hit.GetGLSL(0) .. [[
			#define EMITTER_HEADER ]] .. HEADER_WORDS .. [[u
			#define EMITTER_SOURCE_WORDS ]] .. SOURCE_WORDS .. [[u

			struct emitter_source {
				uint first;
				uint instance;
				uint triangle_count;
				uint flags;
				float luminance;
			};

			layout(scalar, set = 0, binding = 4) readonly buffer EmitterSources { emitter_source sources[]; };
			layout(scalar, set = 0, binding = 5) buffer EmitterWords { uint words[]; };
			shared float scan_data[]] .. SCAN_SIZE .. [[];

			uint ordered_bits(float f) {
				uint bits = floatBitsToUint(f);
				return (bits & 0x80000000u) != 0u ? ~bits : bits | 0x80000000u;
			}

			float ordered_float(uint key) {
				return uintBitsToFloat((key & 0x80000000u) != 0u ? key & 0x7FFFFFFFu : ~key);
			}

			float block_scan(uint lid, float v) {
				scan_data[lid] = v;
				barrier();

				for (uint offset = 1u; offset < ]] .. SCAN_SIZE .. [[u; offset <<= 1u) {
					float add = lid >= offset ? scan_data[lid - offset] : 0.0;
					barrier();
					scan_data[lid] += add;
					barrier();
				}

				return scan_data[lid];
			}
		]]

		local function create(name, shader)
			return EasyPipeline.Compute{
				name = name,
				DescriptorSetCount = slots,
				LocalSize = {x = SCAN_SIZE, y = 1, z = 1},
				storage_buffers = {
					{binding_index = 0},
					{binding_index = 1},
					{binding_index = 2},
					{binding_index = 4},
					{binding_index = 5},
				},
				uniform_buffers = {
					{
						name = "emitter_data",
						binding_index = 3,
						block = {
							{"source_count", "int"},
							{"triangle_count", "int"},
							{"block_count", "int"},
							{"sums_base", "int"},
							{"source_base", "int"},
						},
						write = function(self, block)
							block.source_count = uniform.source_count
							block.triangle_count = uniform.triangle_count
							block.block_count = uniform.block_count
							block.sums_base = uniform.sums_base
							block.source_base = uniform.source_base
							return block
						end,
					},
				},
				custom_declarations = declarations,
				shader = shader,
			}
		end

		pipelines = {
			power = create(
				"scene_emitter_power",
				[[
				void main() {
					uint t = gl_GlobalInvocationID.x;
					uint lid = gl_LocalInvocationID.x;
					float power = 0.0;

					if (t < uint(emitter_data.triangle_count)) {
						uint lo = 0u;
						uint hi = uint(emitter_data.source_count) - 1u;

						while (lo < hi) {
							uint mid = (lo + hi + 1u) >> 1u;

							if (sources[mid].first <= t) {
								lo = mid;
							} else {
								hi = mid - 1u;
							}
						}

						emitter_source source = sources[lo];
						uint primitive = t - source.first;

						if ((scene_instance_flags(source.instance) & 16u) == 0u) {
							scene_triangle tri = scene_hit_tri(source.instance, primitive);
							power = 0.5 * length(cross(tri.e1, tri.e2)) * source.luminance;

							if (!(power > 0.0)) power = 0.0;

							vec3 low = min(tri.v0, min(tri.v0 + tri.e1, tri.v0 + tri.e2));
							vec3 high = max(tri.v0, max(tri.v0 + tri.e1, tri.v0 + tri.e2));
							uint bounds = uint(emitter_data.source_base) + lo * EMITTER_SOURCE_WORDS;

							for (uint i = 0u; i < 3u; i++) {
								atomicMin(words[bounds + i], ordered_bits(low[i]));
								atomicMax(words[bounds + 3u + i], ordered_bits(high[i]));
							}
						}

						uint at = EMITTER_HEADER + t * 4u;
						words[at] = source.instance;
						words[at + 1u] = primitive | source.flags;
						words[at + 3u] = floatBitsToUint(power);
					}

					float sum = block_scan(lid, power);

					if (t < uint(emitter_data.triangle_count)) words[EMITTER_HEADER + t * 4u + 2u] = floatBitsToUint(sum);

					if (lid == ]] .. SCAN_SIZE - 1 .. [[u) words[emitter_data.sums_base + gl_WorkGroupID.x] = floatBitsToUint(sum);
				}
			]]
			),
			blocks = create(
				"scene_emitter_blocks",
				[[
				void main() {
					uint lid = gl_LocalInvocationID.x;
					uint count = uint(emitter_data.block_count);
					float carry = 0.0;

					for (uint base = 0u; base < count; base += ]] .. SCAN_SIZE .. [[u) {
						uint index = base + lid;
						float sum = block_scan(lid, index < count ? uintBitsToFloat(words[emitter_data.sums_base + index]) : 0.0);

						if (index < count) words[emitter_data.sums_base + index] = floatBitsToUint(carry + sum);

						float chunk = scan_data[]] .. SCAN_SIZE - 1 .. [[];
						barrier();
						carry += chunk;
					}
				}
			]]
			),
			cdf = create(
				"scene_emitter_cdf",
				[[
				void main() {
					uint t = gl_GlobalInvocationID.x;
					uint count = uint(emitter_data.triangle_count);
					float total = uintBitsToFloat(words[emitter_data.sums_base + uint(emitter_data.block_count) - 1u]);

					if (t == 0u) {
						words[0] = floatBitsToUint(total);
						words[1] = count;
						words[2] = uint(emitter_data.source_count);
						words[3] = uint(emitter_data.source_base);
					}

					if (t >= count) return;

					uint block = t / ]] .. SCAN_SIZE .. [[u;
					float offset = block > 0u ? uintBitsToFloat(words[emitter_data.sums_base + block - 1u]) : 0.0;
					uint at = EMITTER_HEADER + t * 4u + 2u;
					float cdf = total > 0.0 ? (uintBitsToFloat(words[at]) + offset) / total : 0.0;

					if (t == count - 1u) cdf = 1.0;

					words[at] = floatBitsToUint(cdf);
				}
			]]
			),
			guide = create(
				"scene_emitter_guide",
				[[
				void main() {
					uint k = gl_GlobalInvocationID.x;
					uint count = uint(emitter_data.triangle_count);

					if (k > count) return;

					float u = float(k) / float(count);
					uint lo = 0u;
					uint hi = count - 1u;

					while (lo < hi) {
						uint mid = (lo + hi) >> 1u;

						if (uintBitsToFloat(words[EMITTER_HEADER + mid * 4u + 2u]) <= u) {
							lo = mid + 1u;
						} else {
							hi = mid;
						}
					}

					words[EMITTER_HEADER + count * 4u + k] = lo;
				}
			]]
			),
			bounds = create(
				"scene_emitter_bounds",
				[[
				void main() {
					uint s = gl_GlobalInvocationID.x;

					if (s >= uint(emitter_data.source_count)) return;

					uint at = uint(emitter_data.source_base) + s * EMITTER_SOURCE_WORDS;

					for (uint i = 0u; i < 3u; i++) {
						words[at + i] = 0xFFFFFFFFu;
						words[at + 3u + i] = 0u;
					}
				}
			]]
			),
			sources = create(
				"scene_emitter_sources",
				[[
				float cdf_at(uint t) {
					return uintBitsToFloat(words[EMITTER_HEADER + t * 4u + 2u]);
				}

				void main() {
					uint s = gl_GlobalInvocationID.x;

					if (s >= uint(emitter_data.source_count)) return;

					emitter_source source = sources[s];
					uint at = uint(emitter_data.source_base) + s * EMITTER_SOURCE_WORDS;
					vec3 lo = vec3(ordered_float(words[at]), ordered_float(words[at + 1u]), ordered_float(words[at + 2u]));
					vec3 hi = vec3(ordered_float(words[at + 3u]), ordered_float(words[at + 4u]), ordered_float(words[at + 5u]));

					uint last = source.first + source.triangle_count - 1u;
					float power = (cdf_at(last) - (source.first > 0u ? cdf_at(source.first - 1u) : 0.0)) * uintBitsToFloat(words[0]);
					vec3 center = (lo + hi) * 0.5;
					bool empty = words[at] == 0xFFFFFFFFu;
					words[at] = floatBitsToUint(center.x);
					words[at + 1u] = floatBitsToUint(center.y);
					words[at + 2u] = floatBitsToUint(center.z);
					words[at + 3u] = floatBitsToUint(empty ? 0.0 : length(hi - lo) * 0.5);
					words[at + 4u] = floatBitsToUint(empty ? 0.0 : max(power, 0.0));
					words[at + 5u] = source.first;
					words[at + 6u] = source.triangle_count;
					words[at + 7u] = 0u;
				}
			]]
			),
		}
	end

	local function bind(pipeline, slot, buffers)
		bound[pipeline] = bound[pipeline] or {}
		local last = bound[pipeline][slot]

		if not last then
			last = {}
			bound[pipeline][slot] = last
		end

		hit.Bind(pipeline, slot, 0)

		if last[1] ~= buffers[1] then
			pipeline:UpdateDescriptorSet("storage_buffer", slot, 4, 0, buffers[1], buffers[1]:GetSize())
			last[1] = buffers[1]
		end

		if last[2] ~= buffers[2] then
			pipeline:UpdateDescriptorSet("storage_buffer", slot, 5, 0, buffers[2], buffers[2]:GetSize())
			last[2] = buffers[2]
		end
	end

	function emitters.Build(cmd, include_additive)
		local frame = system.GetFrameNumber()
		local emitter_list = emitters.Get(include_additive)

		if built_frame == frame or emitter_list.count == 0 then
			return emitters.GetBuffer()
		end

		built_frame = frame

		if not pipelines then create_pipelines() end

		local count = emitter_list.count
		local blocks = math.ceil(count / SCAN_SIZE)
		local source_base = HEADER_WORDS + count * EMITTER_WORDS + count + 1
		local words = source_base + emitter_list.source_count * SOURCE_WORDS
		local needed = (words + blocks) * 4

		if not words_buffer or words_buffer:GetSize() < needed then
			if words_buffer then words_buffer:Remove() end

			words_buffer = render.CreateBuffer{
				byte_size = math.ceil(needed * 1.5),
				buffer_usage = {"storage_buffer", "transfer_src"},
				memory_property = {"device_local"},
				label = "scene_emitters",
			}
		end

		if uploaded_version ~= emitter_list.sources_version then
			local sources = emitter_list.sources
			local data = SourceArray(math.max(emitter_list.source_count, 1))

			for i = 1, emitter_list.source_count do
				local source = sources[i]
				data[i - 1].first = source.first
				data[i - 1].instance = source.instance
				data[i - 1].triangle_count = source.triangle_count
				data[i - 1].flags = source.flags
				data[i - 1].luminance = source.luminance
			end

			if sources_buffer then sources_buffer:Remove() end

			sources_buffer = render.CreateBuffer{
				byte_size = ffi.sizeof(data),
				buffer_usage = {"storage_buffer"},
				memory_property = {"host_visible", "host_coherent"},
				label = "ddgi_emitter_sources",
				data = data,
			}
			uploaded_version = emitter_list.sources_version
		end

		sums_base = words
		uniform.source_count = emitter_list.source_count
		uniform.triangle_count = count
		uniform.block_count = blocks
		uniform.sums_base = sums_base
		uniform.source_base = source_base
		local slot = (
				(
					render.GetCurrentFrame() or
					1
				) - 1
			) % math.max(render.GetSwapchainImageCount() or 1, 1) + 1
		local buffers = {sources_buffer, words_buffer}
		cmd:PipelineBarrier{
			srcStage = {
				"host",
				"transfer",
				"compute",
				"acceleration_structure_build_khr",
				"ray_tracing_shader_khr",
			},
			dstStage = "compute",
			memoryBarrier = true,
		}

		for i, name in ipairs{"bounds", "power", "blocks", "cdf", "guide", "sources"} do
			local pipeline = pipelines[name]
			bind(pipeline, slot, buffers)
			pipeline:UploadConstants()
			pipeline.pipeline:Dispatch(
				cmd,
				name == "blocks" and
					1 or
					name == "guide" and
					math.ceil((count + 1) / SCAN_SIZE)
					or
					(
						name == "sources" or
						name == "bounds"
					)
					and
					math.ceil(emitter_list.source_count / SCAN_SIZE)
					or
					blocks,
				1,
				1,
				slot,
				pipeline.dynamic_offsets
			)

			if i < 6 then
				cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
			end
		end

		cmd:PipelineBarrier{
			srcStage = "compute",
			dstStage = {"compute", "ray_tracing_shader_khr"},
			memoryBarrier = true,
		}
		return words_buffer
	end

	function emitters.GetBuffer()
		if not words_buffer then
			words_buffer = render.CreateBuffer{
				byte_size = 4096,
				buffer_usage = {"storage_buffer", "transfer_src"},
				memory_property = {"device_local"},
				label = "scene_emitters",
			}
		end

		return words_buffer
	end
end

function emitters.GetActive()
	return emitters.Get(additive:Get())
end

function emitters.GetActiveCount()
	return enabled:Get() and emitters.GetActive().count or 0
end

function emitters.BuildActive(cmd)
	return emitters.Build(cmd, additive:Get())
end

function emitters.GetDeclarationGLSL(binding)
	return (
		[[

		layout(set = 0, binding = %d) readonly buffer SceneEmitters {
			uint emitter_words[];
		};
	]]
	):format(binding)
end

function emitters.GetGLSL()
	return glsl_common.GetHashGLSL() .. [[
		#define EMITTER_HEADER ]] .. HEADER_WORDS .. [[u
		#define EMITTER_SOURCE_WORDS ]] .. SOURCE_WORDS .. [[u
		#define EMITTER_CANDIDATES 16
		#define EMITTER_LOCAL_CANDIDATES 4
		#define EMITTER_LOCAL_SOURCES ]] .. emitters.LOCAL_SOURCES .. [[

		#define EMITTER_DOUBLE_SIDED 0x80000000u

		vec4 emitter_random(uint index, uint frame, uint candidate) {
			return vec4((pcg4d(uvec4(index, candidate, 0x9E3779B9u, 0x85EBCA6Bu)) + frame * uvec4(0xdb4f0b91u, 0xbbe05633u, 0xa0f2ec75u, 0x89e18285u)) >> 8u) / 16777216.0;
		}

		uint emitter_instance(int e) {
			return emitter_words[EMITTER_HEADER + uint(e) * 4u];
		}

		uint emitter_triangle(int e) {
			return emitter_words[EMITTER_HEADER + uint(e) * 4u + 1u];
		}

		float emitter_cdf(int e) {
			return uintBitsToFloat(emitter_words[EMITTER_HEADER + uint(e) * 4u + 2u]);
		}

		int emitter_search(float u, int lo, int hi) {
			while (lo < hi) {
				int mid = (lo + hi) / 2;

				if (emitter_cdf(mid) <= u) {
					lo = mid + 1;
				} else {
					hi = mid;
				}
			}

			return lo;
		}

		int emitter_pick(float u, int count) {
			uint guide = EMITTER_HEADER + uint(count) * 4u;
			uint bucket = min(uint(u * float(count)), uint(count) - 1u);
			return emitter_search(u, int(emitter_words[guide + bucket]), int(emitter_words[guide + bucket + 1u]));
		}

		vec3 emitter_point(scene_triangle tri, vec2 u) {
			if (u.x + u.y > 1.0) u = 1.0 - u;

			return tri.v0 + tri.e1 * u.x + tri.e2 * u.y;
		}

		float emitter_target(int e, vec2 u, vec3 origin, vec3 normal, float radius) {
			uint triangle = emitter_triangle(e);
			scene_triangle tri = scene_hit_tri(emitter_instance(e), triangle & ~EMITTER_DOUBLE_SIDED);
			vec3 to_point = emitter_point(tri, u) - origin;
			float dist2 = dot(to_point, to_point);
			float facing = dot(tri.normal, to_point) * inversesqrt(dist2);

			if ((triangle & EMITTER_DOUBLE_SIDED) != 0u) facing = abs(facing);

			float receiving = normal == vec3(0.0) ? 1.0 : max(dot(normal, to_point) * inversesqrt(dist2), 0.0);
			return max(facing, 0.0) * receiving / max(dist2, radius * radius);
		}

		float emitter_pick_global(uint index, uint frame, int emitter_count, vec3 origin, vec3 normal, float radius, out int emitter) {
			float weights[EMITTER_CANDIDATES];
			int picked[EMITTER_CANDIDATES];
			float total = 0.0;

			for (uint k = 0u; k < uint(EMITTER_CANDIDATES); k++) {
				vec4 u = emitter_random(index, frame, k);
				picked[k] = emitter_pick(u.x, emitter_count);
				weights[k] = emitter_target(picked[k], u.yz, origin, normal, radius) * uintBitsToFloat(emitter_words[0]);
				total += weights[k];
			}

			emitter = 0;

			if (!(total > 0.0)) return 0.0;

			float pick = emitter_random(index, frame, 0x5bd1e995u).x * total;
			uint chosen = uint(EMITTER_CANDIDATES) - 1u;
			float running = 0.0;

			for (uint k = 0u; k < uint(EMITTER_CANDIDATES); k++) {
				running += weights[k];

				if (pick < running) {
					chosen = k;
					break;
				}
			}

			emitter = int(uint(picked[chosen]) | (chosen << 26u));
			return total / float(EMITTER_CANDIDATES);
		}

		bool emitter_local_candidates(uint index, uint frame, int source_count, vec3 origin, vec3 normal, float radius, out int triangles[EMITTER_LOCAL_CANDIDATES], out float weights[EMITTER_LOCAL_CANDIDATES]) {
			uint source_base = emitter_words[3];
			vec4 stream = emitter_random(index, frame, 0x68bc21ebu);
			int picked[EMITTER_LOCAL_CANDIDATES];
			float picked_weight[EMITTER_LOCAL_CANDIDATES];
			float total = 0.0;

			for (int k = 0; k < EMITTER_LOCAL_CANDIDATES; k++) {
				picked[k] = 0;
				picked_weight[k] = 0.0;
				triangles[k] = 0;
				weights[k] = 0.0;
			}

			for (int s = 0; s < source_count; s++) {
				uint at = source_base + uint(s) * EMITTER_SOURCE_WORDS;
				float power = uintBitsToFloat(emitter_words[at + 4u]);

				if (!(power > 0.0)) continue;

				float source_radius = uintBitsToFloat(emitter_words[at + 3u]);
				vec3 to_center = vec3(uintBitsToFloat(emitter_words[at]), uintBitsToFloat(emitter_words[at + 1u]), uintBitsToFloat(emitter_words[at + 2u])) - origin;

				if (normal != vec3(0.0) && dot(normal, to_center) < -source_radius) continue;

				float w = power / max(dot(to_center, to_center), max(source_radius * source_radius, radius * radius));
				total += w;
				float p = w / total;

				for (int k = 0; k < EMITTER_LOCAL_CANDIDATES; k++) {
					if (stream[k] < p) {
						picked[k] = s;
						picked_weight[k] = w;
						stream[k] /= p;
					} else {
						stream[k] = (stream[k] - p) / (1.0 - p);
					}
				}
			}

			if (!(total > 0.0)) return false;

			for (int k = 0; k < EMITTER_LOCAL_CANDIDATES; k++) {
				if (picked_weight[k] <= 0.0) continue;

				uint at = source_base + uint(picked[k]) * EMITTER_SOURCE_WORDS;
				int first = int(emitter_words[at + 5u]);
				int last = first + int(emitter_words[at + 6u]) - 1;
				vec4 u = emitter_random(index, frame, uint(k));
				float lo = first > 0 ? emitter_cdf(first - 1) : 0.0;
				triangles[k] = emitter_search(mix(lo, emitter_cdf(last), u.x), first, last);
				weights[k] = emitter_target(triangles[k], u.yz, origin, normal, radius) * total * uintBitsToFloat(emitter_words[at + 4u]) / picked_weight[k];
			}

			return true;
		}

		float emitter_pick_local(uint index, uint frame, int source_count, vec3 origin, vec3 normal, float radius, out int emitter) {
			int triangles[EMITTER_LOCAL_CANDIDATES];
			float weights[EMITTER_LOCAL_CANDIDATES];
			emitter = 0;

			if (!emitter_local_candidates(index, frame, source_count, origin, normal, radius, triangles, weights)) return 0.0;

			float sum = 0.0;

			for (int k = 0; k < EMITTER_LOCAL_CANDIDATES; k++) {
				sum += weights[k];
			}

			if (!(sum > 0.0)) return 0.0;

			float pick = emitter_random(index, frame, 0x5bd1e995u).x * sum;
			int chosen = EMITTER_LOCAL_CANDIDATES - 1;
			float running = 0.0;

			for (int k = 0; k < EMITTER_LOCAL_CANDIDATES; k++) {
				running += weights[k];

				if (pick < running) {
					chosen = k;
					break;
				}
			}

			emitter = int(uint(triangles[chosen]) | (uint(chosen) << 26u));
			return sum / float(EMITTER_LOCAL_CANDIDATES);
		}

		vec3 emitter_candidate_point(uint index, uint frame, int emitter) {
			int e = int(uint(emitter) & 0x03FFFFFFu);
			return emitter_point(scene_hit_tri(emitter_instance(e), emitter_triangle(e) & ~EMITTER_DOUBLE_SIDED), emitter_random(index, frame, uint(emitter) >> 26u).yz);
		}

		float emitter_pick_sample(uint index, uint frame, int emitter_count, vec3 origin, vec3 normal, float radius, out int emitter, out vec3 point) {
			float weight = emitter_pick_global(index, frame, emitter_count, origin, normal, radius, emitter);
			point = weight > 0.0 ? emitter_candidate_point(index, frame, emitter) : origin;
			return weight;
		}

		float emitter_pick_sample_local(uint index, uint frame, int emitter_count, vec3 origin, vec3 normal, float radius, out int emitter, out vec3 point) {
			int source_count = int(emitter_words[2]);
			float weight = source_count <= EMITTER_LOCAL_SOURCES ?
				emitter_pick_local(index, frame, source_count, origin, normal, radius, emitter) :
				emitter_pick_global(index, frame, emitter_count, origin, normal, radius, emitter);
			point = weight > 0.0 ? emitter_candidate_point(index, frame, emitter) : origin;
			return weight;
		}
	]]
end

function emitters.GetLightGLSL()
	return [[

		vec3 emitter_light(int emitter, vec3 point, vec3 origin, vec3 normal, float weight, out vec3 dir, out float dist) {
			vec3 to_point = point - origin;
			dist = length(to_point);
			dir = to_point / max(dist, 1e-6);

			if (!(weight > 0.0)) return vec3(0.0);

			int e = int(uint(emitter) & 0x03FFFFFFu);
			scene_triangle tri = scene_hit_tri(emitter_instance(e), emitter_triangle(e) & ~EMITTER_DOUBLE_SIDED);
			ddgi_material material = ddgi_materials[tri.material];
			float receiving = normal == vec3(0.0) ? 1.0 : max(dot(normal, dir), 1e-3);
			return ddgi_emission(tri, ddgi_albedo(material, point)) / (dot(material.emissive, vec3(0.2126, 0.7152, 0.0722)) * receiving) * weight;
		}

		vec3 emitter_sample_light(uint index, uint frame, int emitter_count, vec3 origin, vec3 normal, float radius, out vec3 dir, out float dist) {
			int emitter;
			vec3 point;
			float weight = emitter_pick_sample_local(index, frame, emitter_count, origin, normal, radius, emitter, point);
			return emitter_light(emitter, point, origin, normal, weight, dir, dist);
		}
	]]
end

function emitters.ReadBackHeader()
	local data = store.Download(words_buffer, HEADER_WORDS * 4)
	return ffi.cast("float*", data)[0], ffi.cast("uint32_t*", data)[1]
end

return emitters
