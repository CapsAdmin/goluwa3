local render3d = import("goluwa/render3d/render3d.lua")
local radiance_cascades = import("goluwa/render3d/radiance_cascades.lua")
local voxel_gi = import("goluwa/render3d/voxels/global_illumination.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local MAX_CLIPMAPS = voxel_gi.GetMaxClipmapCount()
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local BINDING_OUTPUT = 0
local BINDING_UNIFORM = 1
local BINDING_CASCADE_SOURCE = 2
local BINDING_VOLUME_0 = 3
local BINDING_NORMAL_VOLUME_0 = BINDING_VOLUME_0 + MAX_CLIPMAPS
local BINDING_BVH_NODES = BINDING_NORMAL_VOLUME_0 + MAX_CLIPMAPS
local BINDING_BVH_TRIANGLES = BINDING_BVH_NODES + 1
local BINDING_RESOLVE_DEPTH = BINDING_BVH_TRIANGLES + 1
local USE_BVH = radiance_cascades.BACKEND == "bvh"

local function get_cascade_texture(cascade)
	return function()
		local pipeline = render3d.pipelines["radiance_cascade_" .. cascade]

		if not pipeline then return nil end

		return pipeline:GetFramebuffer(1):GetAttachment(1)
	end
end

local function build_volume_bindings()
	local sampled_images = {}
	local declarations = {}

	for i = 0, MAX_CLIPMAPS - 1 do
		sampled_images[#sampled_images + 1] = {
			binding_index = BINDING_VOLUME_0 + i,
			get_descriptor = function()
				return voxel_gi.GetVolumeDescriptor(i + 1, false)
			end,
		}
		sampled_images[#sampled_images + 1] = {
			binding_index = BINDING_NORMAL_VOLUME_0 + i,
			get_descriptor = function()
				return voxel_gi.GetVolumeDescriptor(i + 1, true)
			end,
		}
		declarations[#declarations + 1] = "layout(set = 0, binding = " .. (
				BINDING_VOLUME_0 + i
			) .. ") uniform sampler2DArray rc_volume_" .. i .. ";"
		declarations[#declarations + 1] = "layout(set = 0, binding = " .. (
				BINDING_NORMAL_VOLUME_0 + i
			) .. ") uniform sampler2DArray rc_normal_" .. i .. ";"
	end

	return sampled_images, table.concat(declarations, "\n")
end

local function build_cascade_pass(cascade, is_top)
	local sampled_images, volume_declarations = build_volume_bindings()
	sampled_images[#sampled_images + 1] = {
		binding_index = BINDING_CASCADE_SOURCE,
		get_texture = get_cascade_texture(cascade + 1),
	}
	return {
		name = "radiance_cascade_" .. cascade,
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"color", "rgba"}},
		},
		framebuffer_count = 1,
		scale = function()
			return radiance_cascades.SCREEN_SCALE
		end,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = BINDING_OUTPUT,
				attachment = 1,
				dst_stage = "compute",
			},
		},
		sampled_images = sampled_images,
		storage_buffers = USE_BVH and
			{
				{binding_index = BINDING_BVH_NODES},
				{binding_index = BINDING_BVH_TRIANGLES},
			} or
			nil,
		uniform_buffers = {
			{
				name = "rc_data",
				binding_index = BINDING_UNIFORM,
				block = radiance_cascades.GetBlockLayout(),
				write = function(self, block)
					return radiance_cascades.WriteBlock(self, block, cascade)
				end,
			},
		},
		-- whichever cascade runs first pulls the clipmap volumes up to date,
		-- the resolve itself no-ops when the voxel content has not changed.
		-- the tree's descriptors are not part of the declarative binding path,
		-- so every cascade has to point them at the current buffers itself
		on_pre_draw = function(self, cmd, frame_index, descriptor_index)
			if is_top then voxel_gi.EnsureResolvedClipmaps(cmd) end

			if USE_BVH then
				scene_bvh.EnsureBuilt()
				scene_bvh.BindBuffers(self, descriptor_index, BINDING_BVH_NODES, BINDING_BVH_TRIANGLES)
			end
		end,
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_cascade;
			layout(set = 0, binding = ]] .. BINDING_CASCADE_SOURCE .. [[) uniform sampler2D upper_cascade_tex;
		]] .. volume_declarations .. (
				USE_BVH and
				scene_bvh.GetDeclarationsGLSL(BINDING_BVH_NODES, BINDING_BVH_TRIANGLES) or
				""
			),
		shader = [[
			const int RC_DIRECTIONS = ]] .. radiance_cascades.GetDirectionCount(cascade) .. [[;
			#define RC_IS_TOP ]] .. (
				is_top and
				1 or
				0
			) .. [[

			#define saturate(x) clamp(x, 0.0, 1.0)

			]] .. compute_helpers.GetScreenHelpersGLSL() .. [[
			]] .. ibl.GetEnvironmentGLSLCode() .. [[
			]] .. radiance_cascades.GetCommonGLSL() .. [[
			]] .. radiance_cascades.GetProbeGLSL("rc_data") .. [[
			]] .. radiance_cascades.GetShadowGLSL("rc_data") .. [[
			]] .. voxel_gi.GetGLSLCode("rc_data.gi") .. [[
			]] .. (
				USE_BVH and
				scene_bvh.GetTraversalGLSL() or
				""
			) .. [[
			]] .. radiance_cascades.GetTraceGLSL("rc_data") .. [[

#if RC_IS_TOP == 0
			vec4 rc_merge_upper(vec2 probe_uv, vec3 world_pos, ivec2 direction_texel) {
				ivec2 upper_size = textureSize(upper_cascade_tex, 0);
				ivec2 upper_grid = max(upper_size / (RC_DIRECTIONS * 2), ivec2(1));
				vec2 upper_coord = probe_uv * vec2(upper_grid) - 0.5;
				ivec2 base = ivec2(floor(upper_coord));
				vec2 ratio = upper_coord - vec2(base);
				ivec2 probe_coords[4];
				vec3 probe_positions[4];

				for (int i = 0; i < 4; i++) {
					probe_coords[i] = clamp(base + rc_bilinear_offset(i), ivec2(0), upper_grid - 1);
					vec2 uv = (vec2(probe_coords[i]) + 0.5) / vec2(upper_grid);
					probe_positions[i] = rc_probe_world_pos(uv, rc_probe_depth(uv));
				}

				vec4 weights = rc_bilinear_weights(
					rc_bilinear_3d_ratio(probe_positions, world_pos, ratio)
				);
				vec4 total = vec4(0.0);

				for (int p = 0; p < 4; p++) {
					if (weights[p] <= 0.0) continue;

					for (int d = 0; d < 4; d++) {
						ivec2 upper_direction = direction_texel * 2 + rc_bilinear_offset(d);
						total += texelFetch(
							upper_cascade_tex,
							upper_direction * upper_grid + probe_coords[p],
							0
						) * (weights[p] * 0.25);
					}
				}

				return total;
			}
#endif

			void main() {
				ivec2 texel = get_screen_pos();
				ivec2 size = imageSize(out_cascade);

				if (!is_screen_pos_in_bounds(texel, size)) return;

				ivec2 probe_grid = max(size / RC_DIRECTIONS, ivec2(1));
				ivec2 probe = texel % probe_grid;
				ivec2 direction_texel = texel / probe_grid;

				if (direction_texel.x >= RC_DIRECTIONS || direction_texel.y >= RC_DIRECTIONS) {
					imageStore(out_cascade, texel, vec4(0.0));
					return;
				}

				vec2 probe_uv = (vec2(probe) + 0.5) / vec2(probe_grid);
				vec2 jitter = rc_direction_jitter(rc_data.rc_frame, rc_data.rc_jitter);
				vec3 direction = rc_oct_decode(
					(vec2(direction_texel) + 0.5 + jitter) / float(RC_DIRECTIONS)
				);
				float depth = rc_probe_depth(probe_uv);

				if (rc_data.rc_enabled == 0 || depth == 1.0) {
					imageStore(out_cascade, texel, vec4(rc_sky(direction), 1.0));
					return;
				}

				vec3 world_pos = rc_probe_world_pos(probe_uv, depth);
				vec3 origin = world_pos + rc_probe_normal(probe_uv) * rc_data.rc_interval.z;
				rc_hit hit;
				vec4 result;

				if (rc_trace_interval(origin, direction, rc_data.rc_interval.x, rc_data.rc_interval.y, hit)) {
					result = vec4(rc_shade_hit(hit), 0.0);
				} else {
#if RC_IS_TOP
					result = vec4(rc_sky(direction), 1.0);
#else
					result = rc_merge_upper(probe_uv, world_pos, direction_texel);
#endif
				}

				imageStore(out_cascade, texel, min(result, vec4(65504.0)));
			}
		]],
	}
end

local function build_resolve_pass()
	return {
		name = "radiance_cascades_resolve",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"color", "rgba"}},
			-- the view depth this pixel resolved at, so next frame can tell
			-- whether its reprojection landed on the same surface
			{"r16_sfloat", {"gi_depth", "r"}},
		},
		framebuffer_count = 2,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = BINDING_OUTPUT,
				attachment = 1,
				dst_stage = {"compute", "fragment"},
			},
			{
				binding_index = BINDING_RESOLVE_DEPTH,
				attachment = 2,
				dst_stage = {"compute", "fragment"},
			},
		},
		sampled_images = {
			{
				binding_index = BINDING_CASCADE_SOURCE,
				get_texture = get_cascade_texture(0),
			},
		},
		uniform_buffers = {
			{
				name = "rc_data",
				binding_index = BINDING_UNIFORM,
				block = radiance_cascades.GetBlockLayout(),
				write = function(self, block)
					return radiance_cascades.WriteBlock(self, block, 0)
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_color;
			layout(set = 0, binding = ]] .. BINDING_RESOLVE_DEPTH .. [[, r16f) uniform writeonly image2D out_gi_depth;
			layout(set = 0, binding = ]] .. BINDING_CASCADE_SOURCE .. [[) uniform sampler2D cascade_tex;
		]],
		shader = [[
			const int RC_DIRECTIONS = ]] .. radiance_cascades.GetDirectionCount(0) .. [[;

			#define saturate(x) clamp(x, 0.0, 1.0)

			]] .. compute_helpers.GetScreenHelpersGLSL() .. [[
			]] .. ibl.GetEnvironmentGLSLCode() .. [[
			]] .. radiance_cascades.GetCommonGLSL() .. [[
			]] .. radiance_cascades.GetProbeGLSL("rc_data") .. [[

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				vec2 uv = get_screen_uv(pos, size);
				float depth = rc_probe_depth(uv);
				vec3 N = rc_probe_normal(uv);
				vec3 sky = sample_environment_irradiance(rc_data.rc_env_irradiance_tex, N) *
					rc_data.rc_interval.w;

				if (depth == 1.0 || rc_data.rc_enabled == 0) {
					imageStore(out_color, pos, vec4(sky, 1.0));
					imageStore(out_gi_depth, pos, vec4(0.0));
					return;
				}

				ivec2 cascade_size = textureSize(cascade_tex, 0);
				ivec2 probe_grid = max(cascade_size / RC_DIRECTIONS, ivec2(1));
				vec2 probe_coord = uv * vec2(probe_grid) - 0.5;
				ivec2 base = ivec2(floor(probe_coord));
				vec4 weights = rc_bilinear_weights(probe_coord - vec2(base));
				ivec2 probe_coords[4];
				vec4 probe_depths;

				for (int i = 0; i < 4; i++) {
					probe_coords[i] = clamp(base + rc_bilinear_offset(i), ivec2(0), probe_grid - 1);
					vec2 probe_uv = (vec2(probe_coords[i]) + 0.5) / vec2(probe_grid);
					probe_depths[i] = rc_linear_depth(rc_probe_depth(probe_uv));
				}

				float depth_span = max(max(probe_depths.x, probe_depths.y), max(probe_depths.z, probe_depths.w)) -
					min(min(probe_depths.x, probe_depths.y), min(probe_depths.z, probe_depths.w));
				float depth_average = dot(probe_depths, vec4(0.25));

				float discontinuity = smoothstep(
					0.02,
					0.10,
					depth_span / max(depth_average, 1e-4)
				);
				vec4 depth_weights = weights /
					(abs(probe_depths - vec4(rc_linear_depth(depth))) + vec4(1e-4));
				weights /= max(dot(weights, vec4(1.0)), 1e-6);
				depth_weights /= max(dot(depth_weights, vec4(1.0)), 1e-6);
				weights = mix(weights, depth_weights, discontinuity);
				vec3 radiance = vec3(0.0);
				float visibility = 0.0;
				float total_weight = 0.0;
				vec2 jitter = rc_direction_jitter(rc_data.rc_frame, rc_data.rc_jitter);

				for (int p = 0; p < 4; p++) {
					if (weights[p] <= 0.0) continue;

					vec3 probe_radiance = vec3(0.0);
					float probe_visibility = 0.0;
					float cosine_sum = 0.0;

					for (int d = 0; d < RC_DIRECTIONS * RC_DIRECTIONS; d++) {
						ivec2 direction_texel = ivec2(d % RC_DIRECTIONS, d / RC_DIRECTIONS);
						vec3 L = rc_oct_decode(
							(vec2(direction_texel) + 0.5 + jitter) / float(RC_DIRECTIONS)
						);
						float cosine = max(dot(N, L), 0.0);

						if (cosine <= 0.0) continue;

						vec4 interval = texelFetch(
							cascade_tex,
							direction_texel * probe_grid + probe_coords[p],
							0
						);
						probe_radiance += interval.rgb * cosine;
						probe_visibility += interval.a * cosine;
						cosine_sum += cosine;
					}

					if (cosine_sum <= 1e-6) continue;

					radiance += probe_radiance * (weights[p] / cosine_sum);
					visibility += probe_visibility * (weights[p] / cosine_sum);
					total_weight += weights[p];
				}

				float view_depth = rc_linear_depth(depth);

				if (total_weight <= 1e-6) {
					imageStore(out_color, pos, vec4(sky, 1.0));
					imageStore(out_gi_depth, pos, vec4(view_depth));
					return;
				}

				vec4 resolved = vec4(
					min(radiance / total_weight, vec3(65504.0)),
					visibility / total_weight
				);
				vec2 prev_uv;
				float expected;

				if (rc_data.rc_history_tex >= 0 && rc_fetch_surface_motion(uv, depth, prev_uv, expected)) {
					if (all(greaterThanEqual(prev_uv, vec2(0.0))) && all(lessThanEqual(prev_uv, vec2(1.0)))) {
						float stored = texture(TEXTURE(rc_data.rc_history_depth_tex), prev_uv).r;

						if (abs(stored - expected) < max(expected * 0.02, 0.05)) {
							vec4 history = texture(TEXTURE(rc_data.rc_history_tex), prev_uv);
							resolved = mix(resolved, history, rc_data.rc_history_blend);
						}
					}
				}

				imageStore(out_color, pos, resolved);
				imageStore(out_gi_depth, pos, vec4(view_depth));
			}
		]],
	}
end

local passes = {}

-- the world space bounce reads voxel gi's probe cascades, and nothing else in
-- the default pass list updates them any more, so radiance cascades has to
-- drive the probe update itself
if radiance_cascades.WORLD_BOUNCE then
	passes[#passes + 1] = {
		name = "radiance_cascades_probes",
		ComputePass = true,
		ColorFormat = {{"r8_unorm", {"dummy", "r"}}},
		FramebufferSize = {x = 1, y = 1},
		framebuffer_count = 1,
		LocalSize = {x = 1, y = 1, z = 1},
		shader = [[
			void main() {}
		]],
		on_draw = function(self, cmd)
			voxel_gi.Draw(cmd)
		end,
	}
end

-- cascades resolve from the longest interval down, each one merging the
-- cascade above it, so the list has to run high to low
for cascade = radiance_cascades.CASCADE_COUNT - 1, 0, -1 do
	passes[#passes + 1] = build_cascade_pass(cascade, cascade == radiance_cascades.CASCADE_COUNT - 1)
end

passes[#passes + 1] = build_resolve_pass()
passes[#passes + 1] = {
	name = "radiance_cascades_denoise",
	ComputePass = true,
	ColorFormat = {
		{"r16g16b16a16_sfloat", {"color", "rgba"}},
	},
	framebuffer_count = 1,
	LocalSize = COMPUTE_LOCAL_SIZE,
	storage_images = {
		{
			binding_index = BINDING_OUTPUT,
			attachment = 1,
			dst_stage = {"compute", "fragment"},
		},
	},
	sampled_images = {
		{
			binding_index = BINDING_CASCADE_SOURCE,
			get_texture = function()
				local resolve = render3d.pipelines.radiance_cascades_resolve

				if not resolve then return nil end

				return resolve:GetFramebuffer(radiance_cascades.GetResolveFramebufferIndex()):GetAttachment(1)
			end,
		},
	},
	uniform_buffers = {
		{
			name = "rc_data",
			binding_index = BINDING_UNIFORM,
			block = radiance_cascades.GetBlockLayout(),
			write = function(self, block)
				return radiance_cascades.WriteBlock(self, block, 0)
			end,
		},
	},
	custom_declarations = [[
		layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_color;
		layout(set = 0, binding = ]] .. BINDING_CASCADE_SOURCE .. [[) uniform sampler2D gi_tex;
	]],
	shader = [[
		const int RC_DENOISE_RADIUS = ]] .. radiance_cascades.DENOISE_RADIUS .. [[;
		const int RC_DENOISE_STRIDE = ]] .. radiance_cascades.DENOISE_STRIDE .. [[;

		#define saturate(x) clamp(x, 0.0, 1.0)

		]] .. compute_helpers.GetScreenHelpersGLSL() .. [[
		]] .. radiance_cascades.GetProbeGLSL("rc_data") .. [[

		void main() {
			ivec2 pos = get_screen_pos();
			ivec2 size = imageSize(out_color);

			if (!is_screen_pos_in_bounds(pos, size)) return;

			vec4 center = texelFetch(gi_tex, pos, 0);
			vec2 uv = get_screen_uv(pos, size);
			float depth = rc_probe_depth(uv);

			if (rc_data.rc_denoise <= 0.0 || depth == 1.0) {
				imageStore(out_color, pos, center);
				return;
			}

			vec3 N = rc_probe_normal(uv);
			float view_depth = rc_linear_depth(depth);
			vec4 total = center;
			float total_weight = 1.0;

			for (int y = -RC_DENOISE_RADIUS; y <= RC_DENOISE_RADIUS; y++) {
				for (int x = -RC_DENOISE_RADIUS; x <= RC_DENOISE_RADIUS; x++) {
					if (x == 0 && y == 0) continue;

					ivec2 tap = clamp(pos + ivec2(x, y) * RC_DENOISE_STRIDE, ivec2(0), size - 1);
					vec2 tap_uv = (vec2(tap) + 0.5) / vec2(size);
					float tap_depth = rc_probe_depth(tap_uv);

					if (tap_depth == 1.0) continue;

					float depth_weight = exp(
						-abs(rc_linear_depth(tap_depth) - view_depth) / max(view_depth * 0.02, 1e-3)
					);
					float weight = depth_weight *
						pow(max(dot(rc_probe_normal(tap_uv), N), 0.0), 16.0) *
						rc_data.rc_denoise;

					if (weight <= 1e-4) continue;

					total += texelFetch(gi_tex, tap, 0) * weight;
					total_weight += weight;
				}
			}

			imageStore(out_color, pos, total / total_weight);
		}
	]],
}
return passes
