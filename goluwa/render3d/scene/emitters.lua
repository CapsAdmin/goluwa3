local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local Material = import("goluwa/render3d/material.lua")
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
local HEADER_WORDS = 4
local EMITTER_WORDS = 4
local NODE_WORDS = 12
local LOCAL_SIZE = 256
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
local built_frame = -1

function emitters.Get(include_additive)
	if
		list.version == bridge.emitter_version and
		list.generation == Material.emission_generation and
		list.additive == include_additive
	then
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

				if luminance > 0 and material:GetEmitsLight() and (include_additive or not additive) then
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
	list.generation = Material.emission_generation
	list.sources_version = (list.sources_version or 0) + 1
	list.sources = sources
	return list
end

do
	local pipelines
	local constants = {
		source_count = 0,
		triangle_count = 0,
		leaf_count = 0,
		node_base = 0,
		key_base = 0,
		level = 0,
		sort_k = 0,
		sort_j = 0,
	}
	local bound = {}
	local uploaded_version = -1
	local sorted_version = -1
	local sorted_buffer

	local function create_pipelines()
		local slots = math.max(render.GetSwapchainImageCount() or 1, 1)
		local declarations = hit.GetGLSL(0) .. [[
			#define EMITTER_HEADER ]] .. HEADER_WORDS .. [[u
			#define EMITTER_NODE_WORDS ]] .. NODE_WORDS .. [[u
			#define EMITTER_DOUBLE_SIDED 0x80000000u
			#define EMITTER_PI 3.14159265359

			struct emitter_source {
				uint first;
				uint instance;
				uint triangle_count;
				uint flags;
				float luminance;
			};

			layout(scalar, set = 0, binding = 4) readonly buffer EmitterSources { emitter_source sources[]; };
			layout(scalar, set = 0, binding = 5) buffer EmitterWords { uint words[]; };

			uint ordered_bits(float f) {
				uint bits = floatBitsToUint(f);
				return (bits & 0x80000000u) != 0u ? ~bits : bits | 0x80000000u;
			}

			float ordered_float(uint key) {
				return uintBitsToFloat((key & 0x80000000u) != 0u ? key & 0x7FFFFFFFu : ~key);
			}
		]]
		local helpers = [[
			uint bounds_base() {
				return uint(compute.key_base) + 2u * uint(compute.leaf_count);
			}

			uint source_of(uint t) {
				uint lo = 0u;
				uint hi = uint(compute.source_count) - 1u;

				while (lo < hi) {
					uint mid = (lo + hi + 1u) >> 1u;

					if (sources[mid].first <= t) {
						lo = mid;
					} else {
						hi = mid - 1u;
					}
				}

				return lo;
			}

			scene_triangle triangle_of(uint t, out uint s) {
				s = source_of(t);
				return scene_hit_tri(sources[s].instance, t - sources[s].first);
			}

			uint node_at(uint node) {
				return uint(compute.node_base) + node * EMITTER_NODE_WORDS;
			}

			void write_node(uint node, vec3 lo, vec3 hi, float power, vec3 axis, float cos_o, uint triangle) {
				uint at = node_at(node);
				words[at] = floatBitsToUint(lo.x);
				words[at + 1u] = floatBitsToUint(lo.y);
				words[at + 2u] = floatBitsToUint(lo.z);
				words[at + 3u] = floatBitsToUint(power);
				words[at + 4u] = floatBitsToUint(hi.x);
				words[at + 5u] = floatBitsToUint(hi.y);
				words[at + 6u] = floatBitsToUint(hi.z);
				words[at + 7u] = floatBitsToUint(cos_o);
				words[at + 8u] = floatBitsToUint(axis.x);
				words[at + 9u] = floatBitsToUint(axis.y);
				words[at + 10u] = floatBitsToUint(axis.z);
				words[at + 11u] = triangle;
			}

			void read_node(uint node, out vec3 lo, out vec3 hi, out float power, out vec3 axis, out float cos_o) {
				uint at = node_at(node);
				lo = vec3(uintBitsToFloat(words[at]), uintBitsToFloat(words[at + 1u]), uintBitsToFloat(words[at + 2u]));
				power = uintBitsToFloat(words[at + 3u]);
				hi = vec3(uintBitsToFloat(words[at + 4u]), uintBitsToFloat(words[at + 5u]), uintBitsToFloat(words[at + 6u]));
				cos_o = uintBitsToFloat(words[at + 7u]);
				axis = vec3(uintBitsToFloat(words[at + 8u]), uintBitsToFloat(words[at + 9u]), uintBitsToFloat(words[at + 10u]));
			}

			uint morton_bits(uint v) {
				v = (v * 0x00010001u) & 0xFF0000FFu;
				v = (v * 0x00000101u) & 0x0F00F00Fu;
				v = (v * 0x00000011u) & 0xC30C30C3u;
				v = (v * 0x00000005u) & 0x49249249u;
				return v;
			}
		]]

		local function create(name, shader)
			return EasyPipeline.Compute{
				name = name,
				DescriptorSetCount = slots,
				LocalSize = {x = LOCAL_SIZE, y = 1, z = 1},
				storage_buffers = {
					{binding_index = 0},
					{binding_index = 1},
					{binding_index = 2},
					{binding_index = 4},
					{binding_index = 5},
				},
				block = {
					{"source_count", "int"},
					{"triangle_count", "int"},
					{"leaf_count", "int"},
					{"node_base", "int"},
					{"key_base", "int"},
					{"level", "int"},
					{"sort_k", "int"},
					{"sort_j", "int"},
				},
				write = function(self, block)
					for key, value in pairs(constants) do
						block[key] = value
					end

					return block
				end,
				custom_declarations = declarations,
				shader = helpers .. shader,
			}
		end

		pipelines = {
			bounds = create(
				"scene_emitter_bounds",
				[[
				void main() {
					if (gl_GlobalInvocationID.x != 0u) return;

					uint at = bounds_base();

					for (uint i = 0u; i < 3u; i++) {
						words[at + i] = 0xFFFFFFFFu;
						words[at + 3u + i] = 0u;
					}
				}
			]]
			),
			centroids = create(
				"scene_emitter_centroids",
				[[
				void main() {
					uint t = gl_GlobalInvocationID.x;

					if (t >= uint(compute.triangle_count)) return;

					uint s;
					scene_triangle tri = triangle_of(t, s);
					vec3 center = tri.v0 + (tri.e1 + tri.e2) / 3.0;
					uint at = bounds_base();

					for (uint i = 0u; i < 3u; i++) {
						atomicMin(words[at + i], ordered_bits(center[i]));
						atomicMax(words[at + 3u + i], ordered_bits(center[i]));
					}
				}
			]]
			),
			keys = create(
				"scene_emitter_keys",
				[[
				void main() {
					uint j = gl_GlobalInvocationID.x;

					if (j >= uint(compute.leaf_count)) return;

					uint key = 0xFFFFFFFFu;

					if (j < uint(compute.triangle_count)) {
						uint s;
						scene_triangle tri = triangle_of(j, s);
						uint at = bounds_base();
						vec3 lo = vec3(ordered_float(words[at]), ordered_float(words[at + 1u]), ordered_float(words[at + 2u]));
						vec3 hi = vec3(ordered_float(words[at + 3u]), ordered_float(words[at + 4u]), ordered_float(words[at + 5u]));
						uvec3 cell = uvec3(clamp((tri.v0 + (tri.e1 + tri.e2) / 3.0 - lo) / max(hi - lo, vec3(1e-6)), 0.0, 1.0) * 1023.0);
						key = morton_bits(cell.x) << 2u | morton_bits(cell.y) << 1u | morton_bits(cell.z);
					}

					words[uint(compute.key_base) + 2u * j] = key;
					words[uint(compute.key_base) + 2u * j + 1u] = j;
				}
			]]
			),
			sort = create(
				"scene_emitter_sort",
				[[
				void main() {
					uint i = gl_GlobalInvocationID.x;
					uint l = i ^ uint(compute.sort_j);

					if (i >= uint(compute.leaf_count) || l <= i) return;

					uint a = uint(compute.key_base) + 2u * i;
					uint b = uint(compute.key_base) + 2u * l;
					uint key_a = words[a];
					uint key_b = words[b];

					if ((key_a > key_b) == ((i & uint(compute.sort_k)) == 0u)) {
						uint index_a = words[a + 1u];
						words[a] = key_b;
						words[a + 1u] = words[b + 1u];
						words[b] = key_a;
						words[b + 1u] = index_a;
					}
				}
			]]
			),
			leaves = create(
				"scene_emitter_leaves",
				[[
				void main() {
					uint j = gl_GlobalInvocationID.x;

					if (j == 0u) {
						words[1] = uint(compute.triangle_count);
						words[2] = uint(compute.leaf_count);
						words[3] = uint(compute.node_base);
					}

					if (j >= uint(compute.leaf_count)) return;

					uint t = words[uint(compute.key_base) + 2u * j + 1u];
					uint node = uint(compute.leaf_count) + j;

					if (t >= uint(compute.triangle_count)) {
						write_node(node, vec3(0.0), vec3(0.0), 0.0, vec3(0.0, 0.0, 1.0), 1.0, 0u);
						return;
					}

					uint s;
					scene_triangle tri = triangle_of(t, s);
					emitter_source source = sources[s];
					float power = 0.0;

					if ((scene_instance_flags(source.instance) & 16u) == 0u) {
						power = 0.5 * length(cross(tri.e1, tri.e2)) * source.luminance;

						if (!(power > 0.0) || isinf(power)) power = 0.0;
					}

					uint at = EMITTER_HEADER + t * 4u;
					words[at] = source.instance;
					words[at + 1u] = (t - source.first) | source.flags;
					words[at + 2u] = 0u;
					words[at + 3u] = floatBitsToUint(power);
					vec3 a = tri.v0 + tri.e1;
					vec3 b = tri.v0 + tri.e2;
					// cross(e1, e2) points into the mesh, the light leaves the other side; a leaf keeps its plane offset where nodes keep the cone angle
					write_node(node, min(tri.v0, min(a, b)), max(tri.v0, max(a, b)), power, -tri.normal, dot(-tri.normal, tri.v0), t | (source.flags & EMITTER_DOUBLE_SIDED));
				}
			]]
			),
			level = create(
				"scene_emitter_level",
				[[
				void main() {
					uint first = 1u << uint(compute.level);
					uint node = first + gl_GlobalInvocationID.x;

					if (node >= first * 2u) return;

					vec3 lo_a, hi_a, axis_a, lo_b, hi_b, axis_b;
					float power_a, cos_a, power_b, cos_b;
					read_node(node * 2u, lo_a, hi_a, power_a, axis_a, cos_a);
					read_node(node * 2u + 1u, lo_b, hi_b, power_b, axis_b, cos_b);

					if (node * 2u >= uint(compute.leaf_count)) {
						cos_a = (words[node_at(node * 2u) + 11u] & EMITTER_DOUBLE_SIDED) != 0u ? -1.0 : 1.0;
						cos_b = (words[node_at(node * 2u + 1u) + 11u] & EMITTER_DOUBLE_SIDED) != 0u ? -1.0 : 1.0;
					}

					if (!(power_b > 0.0)) {
						write_node(node, lo_a, hi_a, power_a, axis_a, cos_a, 0u);
					} else if (!(power_a > 0.0)) {
						write_node(node, lo_b, hi_b, power_b, axis_b, cos_b, 0u);
					} else {
						float theta_a = acos(clamp(cos_a, -1.0, 1.0));
						float theta_b = acos(clamp(cos_b, -1.0, 1.0));

						if (theta_b > theta_a) {
							vec3 axis = axis_a;
							axis_a = axis_b;
							axis_b = axis;
							float theta = theta_a;
							theta_a = theta_b;
							theta_b = theta;
						}

						float theta_d = acos(clamp(dot(axis_a, axis_b), -1.0, 1.0));
						vec3 axis = axis_a;
						float theta_o = theta_a;

						if (min(theta_d + theta_b, EMITTER_PI) > theta_a + 1e-5) {
							theta_o = 0.5 * (theta_a + theta_d + theta_b);
							vec3 k = cross(axis_a, axis_b);
							float k_length = length(k);

							if (theta_o >= EMITTER_PI || k_length < 1e-6) {
								theta_o = EMITTER_PI;
							} else {
								float rotate = theta_o - theta_a;
								axis = normalize(axis_a * cos(rotate) + cross(k / k_length, axis_a) * sin(rotate));
							}
						}

						write_node(node, min(lo_a, lo_b), max(hi_a, hi_b), power_a + power_b, axis, cos(theta_o), 0u);
					}

					if (node == 1u) {
						float total = uintBitsToFloat(words[node_at(1u) + 3u]);
						words[0] = floatBitsToUint(total);
					}
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

	local function dispatch(cmd, slot, buffers, name, threads)
		local pipeline = pipelines[name]
		bind(pipeline, slot, buffers)
		pipeline:UploadConstants()
		pipeline.pipeline:Dispatch(cmd, math.ceil(threads / LOCAL_SIZE), 1, 1, slot, pipeline.dynamic_offsets)
		cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
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
		local leaf_count = 2

		while leaf_count < count do
			leaf_count = leaf_count * 2
		end

		local node_base = HEADER_WORDS + count * EMITTER_WORDS
		local key_base = node_base + 2 * leaf_count * NODE_WORDS
		local needed = (key_base + 2 * leaf_count + 6) * 4

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

		constants.source_count = emitter_list.source_count
		constants.triangle_count = count
		constants.leaf_count = leaf_count
		constants.node_base = node_base
		constants.key_base = key_base
		local slot = (
				(
					render.GetCurrentFrame() or
					1
				) - 1
			) % math.max(render.GetSwapchainImageCount() or 1, 1) + 1
		local buffers = {sources_buffer, words_buffer}
		render.PushCommandBuffer(cmd)
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

		if sorted_version ~= emitter_list.sources_version or sorted_buffer ~= words_buffer then
			sorted_version = emitter_list.sources_version
			sorted_buffer = words_buffer
			dispatch(cmd, slot, buffers, "bounds", 1)
			dispatch(cmd, slot, buffers, "centroids", count)
			dispatch(cmd, slot, buffers, "keys", leaf_count)
			local k = 2

			while k <= leaf_count do
				local j = k / 2

				while j >= 1 do
					constants.sort_k = k
					constants.sort_j = j
					dispatch(cmd, slot, buffers, "sort", leaf_count)
					j = j / 2
				end

				k = k * 2
			end
		end

		dispatch(cmd, slot, buffers, "leaves", leaf_count)
		local level = math.floor(math.log(leaf_count) / math.log(2) + 0.5) - 1

		while level >= 0 do
			constants.level = level
			dispatch(cmd, slot, buffers, "level", 2 ^ level)
			level = level - 1
		end

		cmd:PipelineBarrier{
			srcStage = "compute",
			dstStage = {"compute", "ray_tracing_shader_khr"},
			memoryBarrier = true,
		}
		render.PopCommandBuffer()
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
		#define EMITTER_NODE_WORDS ]] .. NODE_WORDS .. [[u
		#ifndef EMITTER_CANDIDATES
		#define EMITTER_CANDIDATES 4
		#endif
		#define EMITTER_CLUSTER 16
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

		float emitter_power(int e) {
			return uintBitsToFloat(emitter_words[EMITTER_HEADER + uint(e) * 4u + 3u]);
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

		float emitter_cos_sub(float sin_a, float cos_a, float sin_b, float cos_b) {
			return cos_a > cos_b ? 1.0 : cos_a * cos_b + sin_a * sin_b;
		}

		float emitter_sin_sub(float sin_a, float cos_a, float sin_b, float cos_b) {
			return cos_a > cos_b ? 0.0 : sin_a * cos_b - cos_a * sin_b;
		}

		// x weighs a node by the distance to its box, y by the distance to its centre: the box overrates a big node that holds the receiver but whose emitters are far (it starves a small light beside the receiver), the centre underrates one whose near corner touches the receiver
		vec2 emitter_node_importance(uint node, vec3 origin, vec3 normal, float radius) {
			uint at = emitter_words[3] + node * EMITTER_NODE_WORDS;
			float power = uintBitsToFloat(emitter_words[at + 3u]);

			if (!(power > 0.0)) return vec2(0.0);

			vec3 lo = vec3(uintBitsToFloat(emitter_words[at]), uintBitsToFloat(emitter_words[at + 1u]), uintBitsToFloat(emitter_words[at + 2u]));
			vec3 hi = vec3(uintBitsToFloat(emitter_words[at + 4u]), uintBitsToFloat(emitter_words[at + 5u]), uintBitsToFloat(emitter_words[at + 6u]));
			float cos_o = uintBitsToFloat(emitter_words[at + 7u]);
			vec3 axis = vec3(uintBitsToFloat(emitter_words[at + 8u]), uintBitsToFloat(emitter_words[at + 9u]), uintBitsToFloat(emitter_words[at + 10u]));

			if (normal != vec3(0.0) && dot(normal, (lo + hi) * 0.5 - origin) + dot(abs(normal), (hi - lo) * 0.5) <= 0.0) return vec2(0.0);

			if (node >= emitter_words[2]) {
				bool double_sided = (emitter_words[at + 11u] & EMITTER_DOUBLE_SIDED) != 0u;

				if (!double_sided && dot(axis, origin) <= cos_o) return vec2(0.0);

				cos_o = double_sided ? -1.0 : 1.0;
			}
			vec3 to_origin = origin - (lo + hi) * 0.5;
			float r2 = dot(hi - lo, hi - lo) * 0.25;
			float d2 = dot(to_origin, to_origin);
			vec3 wi = d2 > 0.0 ? to_origin * inversesqrt(d2) : vec3(0.0, 1.0, 0.0);
			float cos_b = d2 > r2 ? sqrt(1.0 - r2 / d2) : -1.0;
			float sin_b = sqrt(max(1.0 - cos_b * cos_b, 0.0));
			float cos_w = dot(axis, wi);
			float sin_w = sqrt(max(1.0 - cos_w * cos_w, 0.0));
			float sin_o = sqrt(max(1.0 - cos_o * cos_o, 0.0));
			float cos_x = emitter_cos_sub(sin_w, cos_w, sin_o, cos_o);
			float sin_x = emitter_sin_sub(sin_w, cos_w, sin_o, cos_o);
			float cos_p = emitter_cos_sub(sin_x, cos_x, sin_b, cos_b);

			if (cos_p <= 0.0) return vec2(0.0);

			vec3 outside = max(max(lo - origin, origin - hi), vec3(0.0));
			vec2 importance = power * cos_p / vec2(max(dot(outside, outside), radius * radius), max(d2, max(r2, radius * radius)));

			if (normal != vec3(0.0)) {
				float cos_i = -dot(normal, wi);
				float cos_pi = emitter_cos_sub(sqrt(max(1.0 - cos_i * cos_i, 0.0)), cos_i, sin_b, cos_b);

				if (cos_pi <= 0.0) return vec2(0.0);

				importance *= cos_pi;
			}

			return importance;
		}

		// walks by one of the two weighings and returns the average of both paths' probabilities, so neither can leave an emitter all but unpicked
		int emitter_tree_pick(float u, uint seed, bool by_centre, vec3 origin, vec3 normal, float radius, out float pdf) {
			uint leaf_count = emitter_words[2];
			uint span = min(uint(EMITTER_CLUSTER), leaf_count);
			uint node = 1u;
			vec2 path = vec2(1.0);
			pdf = 0.0;

			while (node < leaf_count / span) {
				// rescaling u at every level runs out of bits a few unlikely branches down, so each level adds fresh ones
				seed = seed * 747796405u + 2891336453u;
				u = fract(u + float((seed ^ (seed >> 16u)) >> 8u) / 16777216.0);
				vec2 a = emitter_node_importance(node * 2u, origin, normal, radius);
				vec2 b = emitter_node_importance(node * 2u + 1u, origin, normal, radius);

				if (!(a.x + b.x > 0.0)) return -1;

				vec2 p = a / (a + b);
				float q = by_centre ? p.y : p.x;

				if (u < q) {
					u /= q;
					path *= p;
					node = node * 2u;
				} else {
					u = (u - q) / (1.0 - q);
					path *= 1.0 - p;
					node = node * 2u + 1u;
				}

				u = min(u, 0.99999994);
			}

			uint first = node * span;
			vec2 importances[EMITTER_CLUSTER];
			vec2 total = vec2(0.0);

			for (uint i = 0u; i < span; i++) {
				importances[i] = emitter_node_importance(first + i, origin, normal, radius);
				total += importances[i];
			}

			if (!(total.x > 0.0)) return -1;

			seed = seed * 747796405u + 2891336453u;
			float pick = fract(u + float((seed ^ (seed >> 16u)) >> 8u) / 16777216.0) * (by_centre ? total.y : total.x);
			float running = 0.0;
			uint leaf = first + span - 1u;
			vec2 chosen = vec2(0.0);

			for (uint i = 0u; i < span; i++) {
				running += by_centre ? importances[i].y : importances[i].x;

				if (importances[i].x > 0.0) {
					leaf = first + i;
					chosen = importances[i];

					if (pick < running) break;
				}
			}

			path *= chosen / total;
			pdf = 0.5 * (path.x + path.y);
			return int(emitter_words[emitter_words[3] + leaf * EMITTER_NODE_WORDS + 11u] & ~EMITTER_DOUBLE_SIDED);
		}

		bool emitter_candidates(uint index, uint frame, vec3 origin, vec3 normal, float radius, out int triangles[EMITTER_CANDIDATES], out float weights[EMITTER_CANDIDATES]) {
			bool found = false;

			for (int k = 0; k < EMITTER_CANDIDATES; k++) {
				vec4 u = emitter_random(index, frame, uint(k));
				float pdf;
				int e = emitter_tree_pick(u.x, pcg4d(uvec4(index, uint(k), frame, 0x27d4eb2du)).x, (k & 1) != 0, origin, normal, radius, pdf);
				triangles[k] = max(e, 0);
				weights[k] = 0.0;

				if (e < 0 || !(pdf > 0.0)) continue;

				weights[k] = emitter_target(e, u.yz, origin, normal, radius) * emitter_power(e) / pdf;
				found = found || weights[k] > 0.0;
			}

			return found;
		}

		float emitter_pick(uint index, uint frame, vec3 origin, vec3 normal, float radius, out int emitter) {
			int triangles[EMITTER_CANDIDATES];
			float weights[EMITTER_CANDIDATES];
			emitter = 0;

			if (!emitter_candidates(index, frame, origin, normal, radius, triangles, weights)) return 0.0;

			float sum = 0.0;

			for (int k = 0; k < EMITTER_CANDIDATES; k++) {
				sum += weights[k];
			}

			if (!(sum > 0.0)) return 0.0;

			float pick = emitter_random(index, frame, 0x5bd1e995u).x * sum;
			int chosen = EMITTER_CANDIDATES - 1;
			float running = 0.0;

			for (int k = 0; k < EMITTER_CANDIDATES; k++) {
				running += weights[k];

				if (pick < running) {
					chosen = k;
					break;
				}
			}

			emitter = int(uint(triangles[chosen]) | (uint(chosen) << 26u));
			return sum / float(EMITTER_CANDIDATES);
		}

		vec3 emitter_candidate_point(uint index, uint frame, int emitter) {
			int e = int(uint(emitter) & 0x03FFFFFFu);
			return emitter_point(scene_hit_tri(emitter_instance(e), emitter_triangle(e) & ~EMITTER_DOUBLE_SIDED), emitter_random(index, frame, uint(emitter) >> 26u).yz);
		}

		float emitter_pick_sample(uint index, uint frame, vec3 origin, vec3 normal, float radius, out int emitter, out vec3 point) {
			float weight = emitter_pick(index, frame, origin, normal, radius, emitter);
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

		vec3 emitter_sample_light(uint index, uint frame, vec3 origin, vec3 normal, float radius, out vec3 dir, out float dist) {
			int emitter;
			vec3 point;
			float weight = emitter_pick_sample(index, frame, origin, normal, radius, emitter, point);
			return emitter_light(emitter, point, origin, normal, weight, dir, dist);
		}
	]]
end

function emitters.ReadBackHeader()
	local data = store.Download(words_buffer, HEADER_WORDS * 4)
	return ffi.cast("float*", data)[0], ffi.cast("uint32_t*", data)[1]
end

return emitters
