local render = import("goluwa/render/render.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local assets = import("goluwa/assets.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local surface_weather = import("goluwa/render3d/surface_weather.lua")
local surface_features = import("goluwa/render3d/surface_features.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local system = import("goluwa/system.lua")
local pvars = import("goluwa/cli/pvars.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local scene_reflection = import("goluwa/render3d/scene_reflection.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local RAY_QUERY = scene_reflection.RAY_QUERY
pvars.StartGroup("Lighting", "Reflections", {store = false, prefix = "reflection_"})
local rough_rays = scene_reflection.rough_rays
local filter_radius = scene_reflection.filter_radius
local hit_reprojection = pvars.Setup2{
	key = "reflection_hit_reprojection",
	default = true,
	help = "the history of a reflection is read where the reflected image was last frame, found from the hit distance, and not where the surface was. off, the reflection drags along with the surface and bends when the camera moves",
}
local debug_scene = pvars.Setup2{
	key = "reflection_debug_scene",
	default = false,
	help = "shows the scene the reflection rays trace, from the camera: the same hit shading, lights, probes and fog a reflection of it has (at the resolution of the reflections)",
}
local SCALES = scene_reflection.RESOLUTION_SCALES
local resolution = pvars.Setup2{
	key = "reflection_resolution",
	default = "half",
	enums = {"full", "half", "quarter"},
	help = "the resolution the reflections are traced and filtered at, relative to the screen. full traces a ray for every pixel (4 times the work of half), quarter a ray for every 4 by 4 pixels. the filter radius is the same on screen at every resolution",
	callback = function()
		local pipelines = render3d.pipelines

		if pipelines and pipelines.reflections_trace then
			pipelines.reflections_trace:RecreateFramebuffers()
			pipelines.reflections:RecreateFramebuffers()
		end
	end,
}

local function get_scale()
	return SCALES[resolution:Get()]
end

pvars.EndGroup()
local shared_glsl = [[
			#define SCREENSPACE_MAX_STEPS 48
			#define SCREENSPACE_BINARY_STEPS 6
			#define SCREENSPACE_STRIDE 2.0
			#define SCREENSPACE_MAX_DISTANCE 80.0
			#define REFLECTION_ROUGHNESS_CUTOFF (reflection_data.roughness_cutoff)
			#define SCREENSPACE_CONE_TAPS 9
			#define REFLECTION_CLAMP_SIGMA 3.0
			#define REFLECTION_HIST_LO 0.9
			#define REFLECTION_HIST_HI 0.97
			#define REFLECTION_SPATIAL_NORMAL_POWER 32.0
			#define REFLECTION_FILTER_TAPS 16
			ivec2 reflection_size;
			ivec2 gbuffer_size;
			vec4 inv_projection_row_z;
			vec4 inv_projection_row_w;
			float max_hit_luminance;

			float get_firefly_weight(vec3 color, float limit) {
				return 1.0 / (1.0 + luminance(color) / max(limit * 0.1, 1e-6));
			}

			float linearize_depth(vec2 uv, float depth) {
				vec4 clip = vec4(uv * 2.0 - 1.0, depth, 1.0);
				return dot(inv_projection_row_z, clip) / dot(inv_projection_row_w, clip);
			}

]] .. screen_reconstruct.GetViewPosGLSL("reflection_data") .. [[

			float fetch_depth(vec2 uv) {
				return gbuffer_depth(clamp(ivec2(uv * vec2(gbuffer_size)), ivec2(0), gbuffer_size - 1));
			}

			bool fetch_surface_motion(vec2 uv, out vec2 prev_uv, out float prev_depth) {
				if (reflection_data.velocity_tex != -1) {
					vec3 motion = texture(TEXTURE(reflection_data.velocity_tex), uv).rgb;
					prev_uv = uv - motion.xy + reflection_data.jitter_shift;
					prev_depth = motion.z;
					return prev_depth > 1e-5;
				}

				vec3 world_pos = get_world_pos(uv, fetch_depth(uv));
				vec4 prev_view_pos = reflection_data.prev_view * vec4(world_pos, 1.0);
				vec4 prev_clip = reflection_data.prev_projection * prev_view_pos;

				if (prev_clip.w <= 1e-5) return false;

				prev_uv = prev_clip.xy / prev_clip.w * 0.5 + 0.5 + reflection_data.jitter_shift;
				prev_depth = -prev_view_pos.z;
				return true;
			}

]]
local REFLECTION_BINDINGS = {scene = 5, hit = 30, materials = 7, light_grid = 9}
local function get_uniform_buffers(with_ddgi)
	return {
		{
			name = "reflection_data",
			binding_index = 3,
			block = {
				render3d.camera_block,
				gbuffer_layout.block,
				surface_weather.rain_surface_block,
				render3d.last_frame_block,
				{"blue_noise_tex", "int"},
				{"exposure_tex", "int"},
				{"env_tex", "int"},
				{"history_tex", "int"},
				{"history_depth_tex", "int"},
				{"frame_index", "int"},
				{"rough_rays", "int"},
				{"debug_scene", "int"},
				{"raw_tex", "int"},
				{"raw_distance_tex", "int"},
				{"filter_radius", "float"},
				{"roughness_cutoff", "float"},
				{"hit_reprojection", "int"},
				{"jitter_shift", "vec2"},
				{"prev_view", "mat4"},
				{"prev_projection", "mat4"},
				post_source.pre_exposure_block,
				RAY_QUERY and scene_reflection.block or nil,
				RAY_QUERY and atmosphere.GetBlockLayout() or nil,
				RAY_QUERY and {"primary_sun_illuminance", "float"} or nil,
			},
			write = function(self, block)
				render3d.WriteCameraBlock(self, block)
				gbuffer_layout.WriteBlock(self, block)
				surface_weather.WriteRainSurfaceBlock(self, block)
				render3d.WriteLastFrameBlock(self, block)
				post_source.WritePreExposureBlock(self, block)
				block.blue_noise_tex = self:GetTextureIndex(assets.GetTexture("textures/render/blue_noise.lua"))
				block.env_tex = self:GetTextureIndex(render3d.GetEnvironmentTexture())
				local exposure = post_source.GetExposureTexture(true)
				block.exposure_tex = exposure and self:GetTextureIndex(exposure) or -1
				local frame = system.GetFrameNumber()
				block.frame_index = render3d.GetTemporalFrame()
				block.rough_rays = rough_rays:Get()
				block.debug_scene = debug_scene:Get() and 1 or 0
				block.filter_radius = filter_radius:Get()
				block.hit_reprojection = hit_reprojection:Get() and 1 or 0
				local _, gi_end = ibl.GetReflectionGIRange()
				block.roughness_cutoff = gi_end
				local camera = render3d.GetCamera()
				local viewport = camera:GetViewport()
				block.jitter_shift[0] = (render3d.previous_jitter.x - camera:GetJitter().x) / viewport.w
				block.jitter_shift[1] = (render3d.previous_jitter.y - camera:GetJitter().y) / viewport.h

				local reflections = render3d.pipelines.reflections

				if reflections.reflection_history_framebuffers ~= reflections.framebuffers then
					reflections.reflection_history_framebuffers = reflections.framebuffers
					reflections.reflection_history_reset_frame = frame
				end

				block.raw_tex = self:GetTextureIndex(render3d.pipelines.reflections_trace:GetFramebuffer(1):GetAttachment(1))
				block.raw_distance_tex = self:GetTextureIndex(render3d.pipelines.reflections_trace:GetFramebuffer(1):GetAttachment(2))

				if render3d.ShouldUseLastFrameHistory() and frame > reflections.reflection_history_reset_frame then
					local history_fb = reflections:GetFramebuffer((frame + 1) % 2 + 1)
					block.history_tex = self:GetTextureIndex(history_fb:GetAttachment(1))
					block.history_depth_tex = self:GetTextureIndex(history_fb:GetAttachment(2))
				else
					block.history_tex = -1
					block.history_depth_tex = -1
				end

				if RAY_QUERY then
					scene_reflection.WriteBlock(self, block)
					local lights = render3d.GetLights()
					local sun_direction = directional_shadows.GetPrimarySunDirection(lights)
					atmosphere.WriteBlock(self, block, render3d.GetCamera():GetPosition(), sun_direction)
					block.primary_sun_illuminance = directional_shadows.GetPrimarySunIlluminance(lights)
				end

				local prev_view = render3d.GetPreviousViewMatrix()
				local prev_projection = render3d.GetPreviousProjectionMatrix()

				if prev_view then
					prev_view:CopyToFloatPointer(block.prev_view)
				else
					render3d.GetCamera():BuildViewMatrix():CopyToFloatPointer(block.prev_view)
				end

				if prev_projection then
					prev_projection:CopyToFloatPointer(block.prev_projection)
				else
					render3d.GetCamera():BuildProjectionMatrix():CopyToFloatPointer(block.prev_projection)
				end

				return block
			end,
		},
		with_ddgi and RAY_QUERY and scene_reflection.GetDDGIUniformBuffer(8) or nil,
	}
end
return {
	{
		name = "reflections_trace",
		ComputePass = true,
		present_texture = function()
			if not (RAY_QUERY and debug_scene:Get()) then return nil end

			return render3d.pipelines.reflections_trace:GetFramebuffer(1):GetAttachment(1)
		end,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"reflection_raw", "rgba"}},
			{"r16_sfloat", {"reflection_raw_distance", "r"}},
		},
		framebuffer_count = 1,
		scale = get_scale,
		LocalSize = COMPUTE_LOCAL_SIZE,
		ray_generation = RAY_QUERY and
			render.GetDevice().ray_reorder and
			scene_reflection.IsReordered() and
			scene_reflection.GetRayGeneration() or
			nil,
		storage_images = {
			{
				binding_index = 0,
				attachment = 1,
				dst_stage = {"compute", "fragment"},
			},
			{
				binding_index = 1,
				attachment = 2,
				dst_stage = {"compute", "fragment"},
			},
		},
		descriptor_sets = RAY_QUERY and
			scene_reflection.GetDescriptorSets(REFLECTION_BINDINGS, "compute") or
			nil,
		on_pre_draw = RAY_QUERY and
			function(self, cmd, frame, desc)
				scene_reflection.Bind(self, cmd, desc, REFLECTION_BINDINGS)
			end or
			nil,
		uniform_buffers = get_uniform_buffers(true),
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_raw;
			layout(set = 0, binding = 1, r16f) uniform writeonly image2D out_raw_distance;
		]] .. (
				RAY_QUERY and
				scene_reflection.GetDeclarationGLSL(REFLECTION_BINDINGS) or
				""
			),
		shader = [[
		]] .. render3d.GetEmissiveGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. glsl_common.GetBlueNoiseGLSL() .. gbuffer_layout.GetDecodeGLSL("reflection_data") .. surface_weather.GetRainSurfaceGLSL("reflection_data") .. [[
		]] .. ibl.GetBRDFGLSLCode() .. ibl.GetReflectionQuadGLSL() .. [[
		]] .. ibl.GetEnvironmentGLSLCode() .. post_source.GetPreExposureGLSL("reflection_data") .. (
				RAY_QUERY and
				atmosphere.GetGLSLDefines("reflection_data", "reflection_data.primary_sun_illuminance") .. atmosphere.GetAerialPerspectiveGLSLCode() .. scene_reflection.GetGLSL("reflection_data") or
				""
			) .. [[
		]] .. screen_reconstruct.GetWorldPosFromUVGLSL("reflection_data") .. [[
		]] .. screen_reconstruct.GetGeometricNormalGLSL("reflection_data", {world_pos_function = "get_world_pos"}) .. [[
		]] .. shared_glsl .. scene_reflection.GetDirectionGLSL() .. [[

			float get_hit_luminance_limit(float roughness) {
				return scene_reflection_hit_luminance_limit(roughness, max_hit_luminance, REFLECTION_ROUGHNESS_CUTOFF);
			}

			float reflection_hit_distance;
			vec2 blue_noise(ivec2 pixel, int sample_index) {
				vec2 xi = blue_noise_texel(TEXTURE(reflection_data.blue_noise_tex), pixel).rg;
				return blue_noise_r2(xi, float((reflection_data.frame_index % 64) * reflection_data.rough_rays + sample_index));
			}

			vec2 get_last_frame_uv(vec2 hit_uv, vec3 hit_view_pos) {
				if (reflection_data.velocity_tex != -1) {
					return hit_uv - texture(TEXTURE(reflection_data.velocity_tex), hit_uv).xy + reflection_data.jitter_shift;
				}

				vec4 world_hit = reflection_data.inv_view * vec4(hit_view_pos, 1.0);
				vec4 prev_clip = reflection_data.prev_projection * (reflection_data.prev_view * vec4(world_hit.xyz, 1.0));

				if (abs(prev_clip.w) <= 1e-5) {
					return vec2(-1.0);
				}

				prev_clip /= prev_clip.w;
				return prev_clip.xy * 0.5 + 0.5 + reflection_data.jitter_shift;
			}

			vec4 trace_screenspace_direction(vec3 pos_vs, vec3 R_vs, float roughness, float jitter) {
				float ray_len = SCREENSPACE_MAX_DISTANCE;

				if (pos_vs.z + R_vs.z * ray_len > -0.05) {
					ray_len = (-0.05 - pos_vs.z) / R_vs.z;
				}

				if (ray_len <= 1e-4) return vec4(0.0);

				vec3 end_vs = pos_vs + R_vs * ray_len;
				vec4 h0 = reflection_data.projection * vec4(pos_vs, 1.0);
				vec4 h1 = reflection_data.projection * vec4(end_vs, 1.0);
				float k0 = 1.0 / h0.w;
				float k1 = 1.0 / h1.w;
				vec2 p0 = h0.xy * k0 * 0.5 + 0.5;
				vec2 p1 = h1.xy * k1 * 0.5 + 0.5;
				float q0 = pos_vs.z * k0;
				float q1 = end_vs.z * k1;
				vec2 delta_px = (p1 - p0) * vec2(reflection_size);
				float pixel_len = max(abs(delta_px.x), abs(delta_px.y));
				int steps = clamp(int(pixel_len / SCREENSPACE_STRIDE), 1, SCREENSPACE_MAX_STEPS);
				float dt = 1.0 / float(steps);
				float t_prev = 0.0;
				float z_prev = pos_vs.z;
				float t = dt * jitter;

				for (int i = 0; i < steps; i++) {
					t = min(t + dt, 1.0);
					vec2 uv = mix(p0, p1, t);

					if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) break;

					float z_ray = mix(q0, q1, t) / mix(k0, k1, t);
					float depth = fetch_depth(uv);

					if (depth > 0.0) {
						float z_surf = linearize_depth(uv, depth);

						if (z_ray < z_surf) {
							float thickness = max(0.15, -z_surf * 0.03) + abs(z_ray - z_prev);
							float depth_diff = z_surf - z_ray;

							if (depth_diff < thickness) {
								float t_lo = t_prev;
								float t_hi = t;
								float refined_diff = depth_diff;

								for (int j = 0; j < SCREENSPACE_BINARY_STEPS; j++) {
									float t_mid = (t_lo + t_hi) * 0.5;
									vec2 uv_mid = mix(p0, p1, t_mid);
									float z_mid = mix(q0, q1, t_mid) / mix(k0, k1, t_mid);
									float depth_mid = fetch_depth(uv_mid);
									float z_surf_mid = depth_mid > 0.0 ? linearize_depth(uv_mid, depth_mid) : -1e30;

									if (z_mid < z_surf_mid) {
										t_hi = t_mid;
										uv = uv_mid;
										depth = depth_mid;
										refined_diff = z_surf_mid - z_mid;
									} else {
										t_lo = t_mid;
									}
								}

								vec3 hit_normal_vs = mat3(reflection_data.view) * gbuffer_normal(uv);

								if (dot(hit_normal_vs, R_vs) > 0.0) {
									t_prev = t;
									z_prev = z_ray;
									continue;
								}

								vec3 hit_vs = get_view_pos(uv, depth);
								vec2 last_frame_uv = get_last_frame_uv(uv, hit_vs);

								if (last_frame_uv.x <= 0.0 || last_frame_uv.x >= 1.0 || last_frame_uv.y <= 0.0 || last_frame_uv.y >= 1.0) {
									return vec4(0.0);
								}

								float edge_fade = 1.0 - pow(max(abs(uv.x - 0.5), abs(uv.y - 0.5)) * 2.0, 3.0);
								edge_fade *= 1.0 - pow(max(abs(last_frame_uv.x - 0.5), abs(last_frame_uv.y - 0.5)) * 2.0, 3.0);
								float dist_fade = 1.0 - smoothstep(SCREENSPACE_MAX_DISTANCE * 0.7, SCREENSPACE_MAX_DISTANCE, length(hit_vs - pos_vs));
								float thick_conf = 1.0 - saturate(refined_diff / max(0.15, -z_surf * 0.03));
								vec3 hit_color;

								if (roughness > SCENE_REFLECTION_MIRROR_THRESHOLD) {
									float radius_uv = roughness * roughness * length(hit_vs - pos_vs) / max(-hit_vs.z, 0.1) * reflection_data.projection[1][1] * 0.5;
									radius_uv = min(radius_uv, 0.05);
									vec3 sum = vec3(0.0);
									float sum_weight = 0.0;
									float limit = get_hit_luminance_limit(roughness);
									float spin = jitter * 6.2831853;

									for (int k = 0; k < SCREENSPACE_CONE_TAPS; k++) {
										float angle = spin + float(k) * 6.2831853 / float(SCREENSPACE_CONE_TAPS);
										vec2 tap_uv = last_frame_uv + vec2(cos(angle), sin(angle)) * radius_uv * (0.35 + 0.65 * fract(jitter * 7.0 + float(k) * 0.381966));
										vec3 tap = texture(TEXTURE(reflection_data.last_frame_tex), tap_uv).rgb / get_previous_pre_exposure();
										float tap_luma = luminance(tap);

										if (tap_luma > limit) tap *= limit / tap_luma;

										float tap_weight = get_firefly_weight(tap, limit);
										sum += tap * tap_weight;
										sum_weight += tap_weight;
									}

									hit_color = sum / sum_weight;
								} else {
									hit_color = texture(TEXTURE(reflection_data.last_frame_tex), last_frame_uv).rgb / get_previous_pre_exposure();
								}

								if (roughness > SCENE_REFLECTION_MIRROR_THRESHOLD) {
									float hit_luma = luminance(hit_color);

									float hit_limit = get_hit_luminance_limit(roughness);

									if (hit_luma > hit_limit) hit_color *= hit_limit / hit_luma;
								}

								reflection_hit_distance = length(hit_vs - pos_vs);
								return vec4(hit_color, edge_fade * dist_fade * thick_conf);
							}
						}
					}

					t_prev = t;
					z_prev = z_ray;
				}

				return vec4(0.0);
			}

			vec4 cast_reflection_ray(vec3 world_pos, vec3 pos_vs, vec3 N, vec3 geometric_N, vec3 V, float roughness, vec2 xi) {
				if (roughness > REFLECTION_ROUGHNESS_CUTOFF) return vec4(0.0);

				N = bend_normal_to_view(N, V);
				float environment_roughness;
				vec3 R_world = scene_reflection_direction(N, V, roughness, xi, environment_roughness);

				float below = dot(R_world, geometric_N);

				if (below < 0.01) R_world = normalize(R_world + geometric_N * (0.01 - 2.0 * below));

				vec3 R_vs = normalize(mat3(reflection_data.view) * R_world);
				bool rt_primary = false;

				#ifdef SCENE_REFLECTION
				rt_primary = scene_reflection_ready() && !scene_reflection_screen_first(roughness);
				#endif

				if (!rt_primary && reflection_data.last_frame_tex == -1) return vec4(0.0);

				vec4 hit = rt_primary ? vec4(0.0) : trace_screenspace_direction(pos_vs, R_vs, roughness, xi.y);

				#ifdef SCENE_REFLECTION
				if (scene_reflection_ready() && hit.a < 0.999) {
					vec3 origin = world_pos + geometric_N * (0.02 + 0.002 * -pos_vs.z);
					float traced_t;
					vec3 traced = trace_scene_reflection(origin, R_world, N, environment_roughness, SCENE_REFLECTION_MAX_DISTANCE, traced_t);
					reflection_hit_distance = traced_t;

					if (roughness > SCENE_REFLECTION_MIRROR_THRESHOLD && traced_t < SCENE_REFLECTION_MAX_DISTANCE) traced = scene_reflection_limit_hit(traced, roughness, get_hit_luminance_limit(roughness));

					return vec4(mix(traced, hit.rgb, hit.a), 1.0);
				}
				#endif

				return hit.a > 0.0 ? hit : vec4(0.0);
			}

			vec2 debug_uv;
]] .. screen_reconstruct.GetWorldRayGLSL("reflection_data", {uv_expr = "debug_uv", function_name = "get_debug_ray"}) .. [[

			void main() {
				ivec2 pos = get_screen_pos();
				reflection_size = imageSize(out_raw);
				gbuffer_size = textureSize(TEXTURE(reflection_data.depth_tex), 0);
				mat4 inv_projection = reflection_data.inv_projection;
				inv_projection_row_z = vec4(inv_projection[0][2], inv_projection[1][2], inv_projection[2][2], inv_projection[3][2]);
				inv_projection_row_w = vec4(inv_projection[0][3], inv_projection[1][3], inv_projection[2][3], inv_projection[3][3]);
				max_hit_luminance = reflection_data.exposure_tex != -1 ? SCENE_REFLECTION_MAX_HIT_LUMINANCE / max(texture(TEXTURE(reflection_data.exposure_tex), vec2(0.5)).r, 1e-8) : 1e30;
				bool in_bounds = is_screen_pos_in_bounds(pos, reflection_size);

				#ifdef SCENE_REFLECTION
				if (reflection_data.debug_scene != 0) {
					if (!in_bounds) return;

					debug_uv = (vec2(pos) + 0.5) / vec2(reflection_size);
					vec3 debug_dir = get_debug_ray();
					float debug_t;
					vec3 radiance = trace_scene_reflection(reflection_data.camera_position.xyz, debug_dir, -debug_dir, 0.0, SCENE_REFLECTION_MAX_DISTANCE, debug_t);
					imageStore(out_raw, pos, vec4(clamp(radiance * get_exposure(), 0.0, 1.0), 1.0));
					imageStore(out_raw_distance, pos, vec4(0.0));
					return;
				}
				#endif

				ivec2 gbuffer_pos = min(get_reflection_gbuffer_pos(pos, reflection_data.frame_index, gbuffer_size, reflection_size), gbuffer_size - 1);
				vec2 uv = (vec2(gbuffer_pos) + 0.5) / vec2(gbuffer_size);
				float depth = in_bounds ? gbuffer_depth(gbuffer_pos) : 1.0;
				vec4 current = vec4(0.0);
				float hit_distance = 0.0;
				vec3 N = vec3(0.0, 1.0, 0.0);
				vec3 world_pos = vec3(0.0);
				float roughness = 1.0;
				float view_depth = 0.0;

				if (depth > 0.0) {
					N = gbuffer_normal(gbuffer_pos);
					roughness = sqrt(gbuffer_roughness(gbuffer_pos));
					world_pos = get_world_pos(uv, depth);
					vec3 pos_vs = (reflection_data.view * vec4(world_pos, 1.0)).xyz;
					view_depth = -pos_vs.z;
					vec3 V = normalize(reflection_data.camera_position.xyz - world_pos);
					vec3 geometric_N = get_geometric_normal(gbuffer_pos, world_pos, depth, V, N);

					float footprint = view_depth / sqrt(max(abs(dot(geometric_N, V)), 0.01)) * 2.0 * reflection_data.inv_projection[1][1] / float(gbuffer_size.y);
					]] .. surface_features.GetReflectionGLSL() .. [[

					int rays = scene_reflection_ray_count(roughness, reflection_data.rough_rays);
					vec4 sum = vec4(0.0);
					float found = 0.0;
					float distance_sum = 0.0;

					for (int ray = 0; ray < rays; ray++) {
						reflection_hit_distance = 0.0;
						vec4 sample_hit = cast_reflection_ray(world_pos, pos_vs, N, geometric_N, V, roughness, blue_noise(pos, ray));
						sum += vec4(sample_hit.rgb * sample_hit.a, sample_hit.a);
						found += sample_hit.a;
						distance_sum += reflection_hit_distance * sample_hit.a;
					}

					hit_distance = found > 0.0 ? distance_sum / found : 0.0;

					current = found > 0.0 ? vec4(sum.rgb / found, found / float(rays)) : vec4(0.0);
				}

				if (!in_bounds) return;

				imageStore(out_raw, pos, current);
				imageStore(out_raw_distance, pos, vec4(hit_distance));
			}
		]],
	},
	{
		name = "reflections",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"reflections", "rgba"}},
			{"r16_sfloat", {"reflection_depth", "r"}},
		},
		framebuffer_count = 2,
		scale = get_scale,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = 0,
				attachment = 1,
				dst_stage = {"compute", "fragment"},
			},
			{
				binding_index = 1,
				attachment = 2,
				dst_stage = {"compute", "fragment"},
			},
		},
		uniform_buffers = get_uniform_buffers(false),
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_reflection;
			layout(set = 0, binding = 1, r16f) uniform writeonly image2D out_reflection_depth;
		]],
		shader = compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("reflection_data") .. scene_reflection.CONSTANTS_GLSL .. [[
		]] .. ibl.GetReflectionQuadGLSL() .. screen_reconstruct.GetWorldPosFromUVGLSL("reflection_data") .. shared_glsl .. [[

			void main() {
				ivec2 pos = get_screen_pos();
				reflection_size = imageSize(out_reflection);
				gbuffer_size = textureSize(TEXTURE(reflection_data.depth_tex), 0);
				mat4 inv_projection = reflection_data.inv_projection;
				inv_projection_row_z = vec4(inv_projection[0][2], inv_projection[1][2], inv_projection[2][2], inv_projection[3][2]);
				inv_projection_row_w = vec4(inv_projection[0][3], inv_projection[1][3], inv_projection[2][3], inv_projection[3][3]);
				max_hit_luminance = reflection_data.exposure_tex != -1 ? SCENE_REFLECTION_MAX_HIT_LUMINANCE / max(texture(TEXTURE(reflection_data.exposure_tex), vec2(0.5)).r, 1e-8) : 1e30;

				if (!is_screen_pos_in_bounds(pos, reflection_size)) return;

				ivec2 gbuffer_pos = min(get_reflection_gbuffer_pos(pos, reflection_data.frame_index, gbuffer_size, reflection_size), gbuffer_size - 1);
				vec2 uv = (vec2(gbuffer_pos) + 0.5) / vec2(gbuffer_size);
				float depth = gbuffer_depth(gbuffer_pos);

				if (depth <= 0.0) {
					imageStore(out_reflection, pos, vec4(0.0));
					imageStore(out_reflection_depth, pos, vec4(0.0));
					return;
				}

				vec4 current = texelFetch(TEXTURE(reflection_data.raw_tex), pos, 0);
				vec3 N = gbuffer_normal(gbuffer_pos);
				float roughness = sqrt(gbuffer_roughness(gbuffer_pos));
				float view_depth = -linearize_depth(uv, depth);
				vec3 moment1 = vec3(0.0);
				vec3 moment2 = vec3(0.0);
				float alpha_accum = 0.0;
				float color_weight = 0.0;
				float total_weight = 0.0;
				float alpha_min = 1.0;
				float alpha_max = 0.0;

				float hit_distance = texelFetch(TEXTURE(reflection_data.raw_distance_tex), pos, 0).r;

				bool has_hit = hit_distance > 0.0 && current.a > 0.5;

				if (hit_distance <= 0.0) hit_distance = 1000.0;

				float lobe_width = 2.0 * hit_distance * roughness * roughness;
				float texel_size = view_depth * 2.0 * reflection_data.inv_projection[1][1] / float(reflection_size.y);
				ivec2 texel_step = gbuffer_size / reflection_size;
				float normal_change = max(
					length(gbuffer_normal(min(gbuffer_pos + ivec2(texel_step.x, 0), gbuffer_size - 1)) - N),
					length(gbuffer_normal(min(gbuffer_pos + ivec2(0, texel_step.y), gbuffer_size - 1)) - N)
				);
				float hit_shift_per_texel = texel_size + 2.0 * hit_distance * normal_change;
				float max_radius = max(1.0, reflection_data.filter_radius * 2.0 / float(texel_step.x));
				float disc_radius = clamp(lobe_width / max(hit_shift_per_texel, 1e-5), 1.0, max_radius);
				float disc_turn = 6.2831853 * fract(52.9829189 * fract(dot(vec2(pos), vec2(0.06711056, 0.00583715))));
				vec3 center_world = get_world_pos(uv, depth);

				for (int tap = 0; tap <= REFLECTION_FILTER_TAPS; tap++) {
					vec2 offset = vec2(0.0);

					if (tap > 0) {
						float angle = disc_turn + float(tap) * 2.39996323;
						offset = vec2(cos(angle), sin(angle)) * sqrt((float(tap) - 0.5) / float(REFLECTION_FILTER_TAPS)) * disc_radius;
					}

					ivec2 sample_pos = pos + ivec2(round(offset));

					if (any(lessThan(sample_pos, ivec2(0))) || any(greaterThanEqual(sample_pos, reflection_size))) continue;

					ivec2 sample_gbuffer_pos = min(get_reflection_gbuffer_pos(sample_pos, reflection_data.frame_index, gbuffer_size, reflection_size), gbuffer_size - 1);
					float sample_gbuffer_depth = gbuffer_depth(sample_gbuffer_pos);

					if (sample_gbuffer_depth <= 0.0) continue;

					vec3 sample_world = get_world_pos((vec2(sample_gbuffer_pos) + 0.5) / vec2(gbuffer_size), sample_gbuffer_depth);
					float plane_distance = abs(dot(N, sample_world - center_world));
					float depth_weight = exp(-plane_distance / max(view_depth * 0.03, 0.03));
					float normal_weight = pow(max(dot(N, gbuffer_normal(sample_gbuffer_pos)), 0.0), REFLECTION_SPATIAL_NORMAL_POWER);
					float roughness_weight = 1.0 - clamp(abs(sqrt(gbuffer_roughness(sample_gbuffer_pos)) - roughness) * 6.0, 0.0, 1.0);
					float weight = depth_weight * normal_weight * roughness_weight;

					if (weight <= 0.0001) continue;

					vec4 sample_value = texelFetch(TEXTURE(reflection_data.raw_tex), sample_pos, 0);
					float sample_color_weight = weight * sample_value.a * get_firefly_weight(sample_value.rgb, max_hit_luminance);
					moment1 += sample_value.rgb * sample_color_weight;
					moment2 += sample_value.rgb * sample_value.rgb * sample_color_weight;
					color_weight += sample_color_weight;
					alpha_accum += sample_value.a * weight;
					total_weight += weight;
					alpha_min = min(alpha_min, sample_value.a);
					alpha_max = max(alpha_max, sample_value.a);
				}

				vec4 filtered = current;
				vec3 mean = current.rgb;
				vec3 deviation = vec3(0.0);

				if (color_weight > 0.0001) {
					mean = moment1 / color_weight;
					deviation = sqrt(max(moment2 / color_weight - mean * mean, vec3(0.0)));
					filtered = mix(current, vec4(mean, alpha_accum / total_weight), smoothstep(0.02, 0.15, roughness));
				}

				vec4 result = filtered;

				if (reflection_data.history_tex != -1) {
					vec2 prev_uv;
					float prev_depth;
					bool has_motion = fetch_surface_motion(uv, prev_uv, prev_depth);

					if (has_motion) {
						prev_uv += (vec2(pos) + 0.5) / vec2(reflection_size) - uv;
						float history_weight_scale = 1.0;
						vec2 surface_prev_uv = prev_uv;

						if (reflection_data.hit_reprojection != 0 && has_hit) {
							vec3 view_ray = normalize(center_world - reflection_data.camera_position.xyz);
							vec3 step_x_world = get_world_pos((vec2(min(gbuffer_pos + ivec2(texel_step.x, 0), gbuffer_size - 1)) + 0.5) / vec2(gbuffer_size), gbuffer_depth(min(gbuffer_pos + ivec2(texel_step.x, 0), gbuffer_size - 1))) - center_world;
							vec3 step_y_world = get_world_pos((vec2(min(gbuffer_pos + ivec2(0, texel_step.y), gbuffer_size - 1)) + 0.5) / vec2(gbuffer_size), gbuffer_depth(min(gbuffer_pos + ivec2(0, texel_step.y), gbuffer_size - 1))) - center_world;
							float curvature = 0.5 * (
								dot(gbuffer_normal(min(gbuffer_pos + ivec2(texel_step.x, 0), gbuffer_size - 1)) - N, step_x_world) / max(dot(step_x_world, step_x_world), 1e-8) +
								dot(gbuffer_normal(min(gbuffer_pos + ivec2(0, texel_step.y), gbuffer_size - 1)) - N, step_y_world) / max(dot(step_y_world, step_y_world), 1e-8)
							);
							float image_scale = 1.0 + 2.0 * curvature * hit_distance;
							float image_distance = image_scale > 0.2 ? hit_distance / image_scale : 0.0;
							vec4 static_clip = reflection_data.prev_projection * (reflection_data.prev_view * vec4(center_world, 1.0));
							vec4 image_clip = reflection_data.prev_projection * (reflection_data.prev_view * vec4(center_world + view_ray * image_distance, 1.0));

							if (static_clip.w > 1e-5 && image_clip.w > 1e-5) {
								vec2 image_shift = image_clip.xy / image_clip.w * 0.5 - static_clip.xy / static_clip.w * 0.5;
								float uncorrected = smoothstep(0.1, 0.5, roughness);
								prev_uv += image_shift * (1.0 - uncorrected);
								history_weight_scale = 1.0 - 0.5 * smoothstep(1.0, 6.0, length(image_shift * uncorrected * vec2(reflection_size)));
							}
						}

						if (prev_uv.x > 0.0 && prev_uv.x < 1.0 && prev_uv.y > 0.0 && prev_uv.y < 1.0 && surface_prev_uv.x > 0.0 && surface_prev_uv.x < 1.0 && surface_prev_uv.y > 0.0 && surface_prev_uv.y < 1.0) {
							float history_depth = texture(TEXTURE(reflection_data.history_depth_tex), surface_prev_uv).r;

							if (abs(history_depth - prev_depth) < prev_depth * 0.05 + 0.02) {
								vec4 history = texture(TEXTURE(reflection_data.history_tex), prev_uv);

								if (!any(isnan(history))) {
									vec3 clamp_extent = deviation * REFLECTION_CLAMP_SIGMA + mean * 0.05 + 0.001;
									history.rgb = clamp(history.rgb, mean - clamp_extent, mean + clamp_extent);
									if (alpha_min <= alpha_max) history.a = clamp(history.a, alpha_min, alpha_max);
									float history_weight = mix(REFLECTION_HIST_LO, REFLECTION_HIST_HI, smoothstep(0.0, 0.3, roughness));
									result = mix(filtered, history, history_weight * history_weight_scale);
								}
							}
						}
					}
				}

				imageStore(out_reflection, pos, result);
				imageStore(out_reflection_depth, pos, vec4(view_depth));
			}
		]],
	},
}
