local Vec3 = import("goluwa/structs/vec3.lua")
local assets = import("goluwa/assets.lua")
local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local lightprobes = import("goluwa/render3d/lightprobes.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local get_primary_sun = directional_shadows.GetPrimarySun
local get_primary_sun_direction = directional_shadows.GetPrimarySunDirection
local get_primary_sun_intensity = directional_shadows.GetPrimarySunIntensity
local MAX_LIGHTS = scene_lights.MAX_LIGHTS
local MAX_CASCADES = scene_lights.MAX_CASCADES
local MAX_POINT_SHADOWS = scene_lights.MAX_POINT_SHADOWS
local MAX_PROBES = 64
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
return {
	{
		name = "probe_irradiance",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"color", "rgba"}},
		},
		framebuffer_count = 1,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = 0,
				attachment = 1,
				dst_stage = "fragment",
			},
		},
		uniform_buffers = {
			{
				name = "lighting_data",
				binding_index = 3,
				block = {
					render3d.camera_block,
					{"ssao_kernel", "vec3", 64},
					{"lights", scene_lights.BuildLightsBlockLayout(), 128},
					{"light_count", "int"},
					{"shadows", scene_lights.BuildShadowsBlockLayout()},
					render3d.debug_block,
					render3d.gbuffer_block,
					{"env_tex", "int"},
					{"brdf_lut_tex", "int"},
					{"blue_noise_tex", "int"},
					render3d.last_frame_block,
					render3d.common_block,
					{"primary_sun_intensity", "float"},
					{"primary_sun_color", "vec4"},
					{"primary_sun_direction", "vec4"},
					{"stars_texture_index", "int"},
					{"atmosphere_sky_view_texture_index", "int"},
					{"atmosphere_transmittance_texture_index", "int"},
					{"voxel_irradiance_tex", "int"},
					{"ssr_tex", "int"},
					{"ssgi_filter_2_tex", "int"},
					{"ssgi_raw_tex", "int"},
					{"ssgi_filter_1_tex", "int"},
					{"ssgi_debug_mode", "int"},
					{"probe_color_textures", "int", 64},
					{"probe_depth_textures", "int", 64},
					{"probe_positions", "vec4", 64},
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					local lights = render3d.GetLights()
					local light_count = math.min(#lights, MAX_LIGHTS)
					block.light_count = light_count
					render3d.WriteDebugBlock(self, block)
					render3d.WriteGBufferBlock(self, block)
					block.env_tex = self:GetTextureIndex(render3d.GetEnvironmentTexture())
					block.brdf_lut_tex = self:GetTextureIndex(assets.GetTexture("textures/render/brdf_lut.lua"))
					block.blue_noise_tex = self:GetTextureIndex(assets.GetTexture("textures/render/blue_noise.lua"))
					render3d.WriteLastFrameBlock(self, block)
					render3d.WriteCommonBlock(self, block)
					local primary_sun = get_primary_sun(lights)
					get_primary_sun_direction(lights):CopyToFloatPointer(block.primary_sun_direction)
					block.primary_sun_intensity = get_primary_sun_intensity(lights)
					block.primary_sun_color[0] = primary_sun and primary_sun.Color.x or 1
					block.primary_sun_color[1] = primary_sun and primary_sun.Color.y or 1
					block.primary_sun_color[2] = primary_sun and primary_sun.Color.z or 1
					block.primary_sun_color[3] = 0
					block.stars_texture_index = self:GetTextureIndex(atmosphere.GetStarsTexture())
					block.atmosphere_sky_view_texture_index = self:GetTextureIndex(
						atmosphere.GetSkyViewTexture(render3d.GetCamera():GetPosition(), get_primary_sun_direction(lights))
					)
					block.atmosphere_transmittance_texture_index = self:GetTextureIndex(atmosphere.GetTransmittanceTexture())

					if render3d.pipelines.voxel_irradiance then
						block.voxel_irradiance_tex = self:GetTextureIndex(render3d.pipelines.voxel_irradiance:GetFramebuffer(1):GetAttachment(1))
					end

					if not render3d.pipelines.ssr or not render3d.pipelines.ssr.framebuffers then
						block.ssr_tex = -1
					else
						local current_idx = system.GetFrameNumber() % 2 + 1
						local current_ssr_fb = render3d.pipelines.ssr:GetFramebuffer(current_idx)
						block.ssr_tex = self:GetTextureIndex(current_ssr_fb:GetAttachment(1))
					end

					if render3d.pipelines.ssgi then
						block.ssgi_raw_tex = self:GetTextureIndex(render3d.pipelines.ssgi:GetFramebuffer(system.GetFrameNumber() % 3 + 1):GetAttachment(1))
						block.ssgi_filter_2_tex = self:GetTextureIndex(render3d.pipelines.ssgi_filter_2:GetFramebuffer(1):GetAttachment(1))
						block.ssgi_filter_1_tex = self:GetTextureIndex(render3d.pipelines.ssgi_filter_1:GetFramebuffer(1):GetAttachment(1))
						block.ssgi_debug_mode = render3d.ssgi_debug_mode or 0
					end

					for i = 0, MAX_PROBES - 1 do
						block.probe_color_textures[i] = -1
						block.probe_depth_textures[i] = -1
						block.probe_positions[i][0] = 0
						block.probe_positions[i][1] = 0
						block.probe_positions[i][2] = 0
						block.probe_positions[i][3] = 0
					end

					if
						lightprobes.IsEnabled() and
						lightprobes.AreSceneProbesEnabled() and
						render3d.ShouldUseLightProbes()
					then
						local probes = lightprobes.GetProbes()

						for i = 0, MAX_PROBES - 1 do
							local probe = probes[i + 1]

							if probe then
								if probe.cubemap then
									block.probe_color_textures[i] = self:GetTextureIndex(probe.cubemap)
								end

								if probe.depth_cubemap then
									block.probe_depth_textures[i] = self:GetTextureIndex(probe.depth_cubemap)
								end

								block.probe_positions[i][0] = probe.position.x
								block.probe_positions[i][1] = probe.position.y
								block.probe_positions[i][2] = probe.position.z
								block.probe_positions[i][3] = probe.radius or 20
							end
						end
					end

					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_color;
			]],
		shader = [[
			]] .. compute_helpers.GetScreenHelpersGLSL() .. [[
			vec2 get_compute_uv() {
				return get_screen_uv(get_screen_pos(), imageSize(out_color));
			}

			vec2 in_uv;

			void set_color(vec4 value) {
				imageStore(out_color, get_screen_pos(), value);
			}

			vec3 get_albedo() {
				return texture(TEXTURE(lighting_data.albedo_tex), in_uv).rgb;
			}

			float get_alpha() {
				return texture(TEXTURE(lighting_data.albedo_tex), in_uv).a;
			}

			float get_depth() {
				return texture(TEXTURE(lighting_data.depth_tex), in_uv).r;
			}

			vec3 get_normal() {
				return texture(TEXTURE(lighting_data.normal_tex), in_uv).xyz;
			}

			float get_transmission_view_dependency() {
				return texture(TEXTURE(lighting_data.normal_tex), in_uv).a;
			}

			float get_metallic() {
				vec3 mra = texture(TEXTURE(lighting_data.mra_tex), in_uv).rgb;
				return mra.r;
			}

			float get_roughness() {
				vec3 mra = texture(TEXTURE(lighting_data.mra_tex), in_uv).rgb;
				return mra.g;
			}

			float get_ao() {
				vec3 mra = texture(TEXTURE(lighting_data.mra_tex), in_uv).rgb;
				return mra.b;
			}

			float get_subsurface() {
				return texture(TEXTURE(lighting_data.mra_tex), in_uv).a;
			}

			vec3 get_emissive() {
				return texture(TEXTURE(lighting_data.emissive_tex), in_uv).rgb;
			}

			float get_transmission_blocking() {
				return texture(TEXTURE(lighting_data.emissive_tex), in_uv).a;
			}

			vec3 get_transmission_color() {
				return texture(TEXTURE(lighting_data.emissive_tex), in_uv).rgb;
			}

			#define ATMOSPHERE_SUN_INTENSITY lighting_data.primary_sun_intensity

			]] .. atmosphere.GetGLSLCode() .. [[


			#define SSR 1
			#define PARALLAX_CORRECTION 1
			#define uv in_uv
			float hash(vec2 p) {
				p = fract(p * vec2(123.34, 456.21));
				p += dot(p, p + 45.32);
				return fract(p.x * p.y);
			}

			vec3 random_vec3(vec2 p) {
				return vec3(hash(p), hash(p + 1.0), hash(p + 2.0)) * 2.0 - 1.0;
			}

			#define saturate(x) clamp(x, 0.0, 1.0)
			]] .. ibl.GetBRDFGLSLCode() .. [[

			]] .. ibl.GetEnvironmentGLSLCode() .. [[

			]] .. ibl.GetReflectionGLSLCode("lighting_data") .. [[
			]] .. scene_lights.GetLightGLSLCode() .. [[

			// Cascade debug colors
			const vec3 CASCADE_COLORS[4] = vec3[4](
				vec3(1.0, 0.2, 0.2),  // Red - cascade 1
				vec3(0.2, 1.0, 0.2),  // Green - cascade 2
				vec3(0.2, 0.2, 1.0),  // Blue - cascade 3
				vec3(1.0, 1.0, 0.2)   // Yellow - cascade 4
			);

			float random(vec2 co)
			{
				return fract(sin(dot(co.xy ,vec2(12.9898,78.233))) * 43758.5453);
			}
			vec3 get_noise3_world(vec3 world_pos)
			{
				float x = random(world_pos.xy);
				float y = random(world_pos.yz * x);
				float z = random(world_pos.xz * y);

				return vec3(x, y, z) * 2.0 - 1.0;
			}

			]] .. directional_shadows.GetSurfaceDirectionalShadowGLSL("lighting_data", "calculateShadow", {use_receiver_plane_bias = false}) .. [[

			int getPointShadowSlot(int light_index) {
				for (int i = 0; i < lighting_data.shadows.point_shadow_count; i++) {
					if (lighting_data.shadows.point_shadow_light_indices[i] == light_index) {
						return i;
					}
				}

				return -1;
			}

			float samplePointShadowProjection(int shadow_map_idx, vec3 sample_dir, float current_depth, float bias, float filter_radius_texels) {
				vec3 lookup_dir = normalize(vec3(-sample_dir.x, sample_dir.y, sample_dir.z));
				float face_size = float(textureSize(CUBEMAP(shadow_map_idx), 0).x);
				float angular_radius = filter_radius_texels / max(face_size, 1.0);
				vec3 up = abs(lookup_dir.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
				vec3 tangent = normalize(cross(up, lookup_dir));
				vec3 bitangent = cross(lookup_dir, tangent);
				float visibility = 0.0;
				const vec2 POISSON_DISK[8] = vec2[8](
					vec2(-0.326, -0.406),
					vec2(-0.840, -0.074),
					vec2(-0.696,  0.457),
					vec2(-0.203,  0.621),
					vec2( 0.962, -0.195),
					vec2( 0.473, -0.480),
					vec2( 0.519,  0.767),
					vec2( 0.185, -0.893)
				);

				for (int i = 0; i < 8; i++) {
					vec2 offset = POISSON_DISK[i] * angular_radius;
					vec3 tap_dir = normalize(lookup_dir + tangent * offset.x + bitangent * offset.y);
					float stored_depth = texture(CUBEMAP(shadow_map_idx), tap_dir).r;
					visibility += current_depth - bias > stored_depth ? 0.0 : 1.0;
				}

				return visibility / 8.0;
			}

			float calculatePointShadow(int shadow_slot, vec3 world_pos, vec3 normal, vec3 light_dir) {
				if (shadow_slot < 0 || shadow_slot >= lighting_data.shadows.point_shadow_count) return 1.0;

				int shadow_map_idx = lighting_data.shadows.point_shadow_map_indices[shadow_slot];
				if (shadow_map_idx < 0) return 1.0;

				vec3 light_pos = lighting_data.shadows.point_shadow_positions[shadow_slot].xyz;
				float far_plane = lighting_data.shadows.point_shadow_positions[shadow_slot].w;
				float face_size = float(textureSize(CUBEMAP(shadow_map_idx), 0).x);
				float texel_world_size = far_plane / max(face_size, 1.0);
				float normal_bias = max(texel_world_size * 2.0, 0.01);
				float bias_val = normal_bias * max(1.0 - dot(normal, light_dir), 0.2);
				vec3 offset_pos = world_pos + normal * bias_val;
				vec3 light_to_surface = offset_pos - light_pos;
				float light_distance = length(light_to_surface);

				if (light_distance <= 0.0001 || light_distance >= far_plane) return 1.0;

				vec3 sample_dir = light_to_surface / light_distance;
				float current_depth = light_distance / max(far_plane, 0.0001);
				float normalized_bias = max(bias_val / max(far_plane, 0.0001), 0.0005);
				return samplePointShadowProjection(shadow_map_idx, sample_dir, current_depth, normalized_bias, 1.25);
			}

			float calculateLocalDirectionalShadow(vec3 world_pos, vec3 normal, vec3 light_dir) {
				int shadow_map_idx = lighting_data.shadows.local_directional_shadow_map_index;
				if (shadow_map_idx < 0) return 1.0;

				vec3 proj_coords;

				if (!projectShadowMap(
					lighting_data.shadows.local_directional_light_space_matrix,
					world_pos,
					normal,
					light_dir,
					lighting_data.shadows.local_directional_shadow_texel_world_size,
					proj_coords
				)) {
					return 1.0;
				}

				return sampleShadowProjection(shadow_map_idx, proj_coords, 1.35);
			}
			vec3 correct_probe_depth_lookup_dir(vec3 dir) {
				return normalize(vec3(-dir.x, dir.y, dir.z));
			}

			vec3 get_environment_irradiance(vec3 normal, vec3 world_pos) {
				vec3 global_env = sample_environment_irradiance(lighting_data.env_tex, normal);

				vec3 probes_env = vec3(0.0);
				float total_weight = 0.0;
				float normalized_weight_sum = 0.0;
				float max_weight = 0.0;

				for (int i = 0; i < 64; i++) {
					int color_tex = lighting_data.probe_color_textures[i];
					int depth_tex = lighting_data.probe_depth_textures[i];
					if (color_tex == -1 || depth_tex == -1) continue;

					vec3 probe_pos = lighting_data.probe_positions[i].xyz;
					float sphere_radius = lighting_data.probe_positions[i].w;
					vec3 probe_to_point = world_pos - probe_pos;
					float dist_to_point = length(probe_to_point);

					if (dist_to_point < sphere_radius) {
						vec3 dir_to_point = normalize(probe_to_point);
						float stored_depth = texture(CUBEMAP(depth_tex), correct_probe_depth_lookup_dir(dir_to_point)).r;
						float bias = 0.3;
						float fade_band = 0.75;
						float penetration = dist_to_point - (stored_depth + bias);
						float occlusion_weight = 1.0 - smoothstep(0.0, fade_band, max(penetration, 0.0));

						if (occlusion_weight <= 0.001) continue;

						float depth_diff = abs(stored_depth - dist_to_point);
						float depth_weight = exp(-depth_diff * 0.5);
						float edge_weight = smoothstep(sphere_radius, sphere_radius * 0.3, dist_to_point);
						float weight = depth_weight * edge_weight * occlusion_weight;

						if (weight > 0.001) {
							float normalized_weight = pow(weight, 1.5);
							probes_env += sample_environment_irradiance(color_tex, normal) * normalized_weight;
							total_weight += weight;
							normalized_weight_sum += normalized_weight;
							max_weight = max(max_weight, weight);
						}
					}
				}

				vec3 local_env = probes_env / max(normalized_weight_sum, 0.0001);
				float local_coverage = clamp(max_weight + total_weight * 0.35, 0.0, 1.0);
				return blend_environment_sources(global_env, local_env, local_coverage);
			}

			vec3 get_reflection(vec3 normal, float roughness, vec3 V, vec3 world_pos) {
				if (lighting_data.ssr_tex == -1) {
					vec3 raw_R = reflect(-V, normal);
					return sample_environment_specular(lighting_data.env_tex, raw_R, normal, roughness);
				}

				vec4 ssr = get_filtered_ssr_reflection(in_uv);
				return ssr.rgb;
			}

			vec3 get_ssgi_indirect(vec2 uv, vec3 world_pos, vec3 N, vec3 V) {
				vec4 ssgi = texture(TEXTURE(lighting_data.ssgi_filter_2_tex), uv);
				return ssgi.rgb;
			}

			vec3 get_irradiance(vec3 normal, vec3 V, vec3 world_pos) {
				return get_environment_irradiance(normal, world_pos);
			}

            vec3 get_primary_sun_direction() {
                vec3 sunDir = lighting_data.primary_sun_direction.xyz;
                if (length(sunDir) < 0.0001) {
                    sunDir = vec3(0.0, 1.0, 0.0);
                }
                return normalize(sunDir);
            }

            vec3 get_sky() {
					vec4 clip_pos = vec4(in_uv * 2.0 - 1.0, 1.0, 1.0);
					vec4 view_pos = lighting_data.inv_projection * clip_pos;
					view_pos /= view_pos.w;
					vec3 world_pos = (lighting_data.inv_view * view_pos).xyz;
					vec3 sky_dir = normalize(world_pos - lighting_data.camera_position.xyz);
					vec3 sun_dir = get_primary_sun_direction();
					vec3 sky_color_output = vec3(0.0);

					]] .. atmosphere.GetGLSLMainCode(
				"sky_dir",
				"sun_dir",
				"lighting_data.camera_position.xyz",
				"lighting_data.stars_texture_index",
				"lighting_data.atmosphere_sky_view_texture_index",
				"lighting_data.atmosphere_transmittance_texture_index"
			) .. [[

					return clamp(sky_color_output, vec3(0.0), vec3(65504.0));
				}


			]] .. screen_reconstruct.GetWorldPosGLSL("lighting_data") .. [[

			vec3 get_view_normal(vec3 world_pos) {
				return normalize(lighting_data.camera_position.xyz - world_pos);
			}

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;
				in_uv = get_compute_uv();

				float depth = get_depth();

				if (depth == 1.0) {
					set_color(vec4(0.0, 0.0, 0.0, 1.0));
					return;
				}

				float alpha = get_alpha();

				if (alpha == 0.0) {
					set_color(vec4(0.0, 0.0, 0.0, 0.0));
					return;
				}

				vec3 N = get_normal();
				vec3 world_pos = get_world_pos(depth);
				vec3 V = get_view_normal(world_pos);

				vec3 irradiance = get_irradiance(N, V, world_pos);

				set_color(vec4(irradiance, alpha));
			}
		]],
	},
}
