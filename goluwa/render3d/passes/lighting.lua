local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local light_grid = import("goluwa/render3d/light_grid.lua")
local surface_lighting = import("goluwa/render3d/surface_lighting.lua")
local surface_weather = import("goluwa/render3d/surface_weather.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local pvars = import("goluwa/cli/pvars.lua")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local BINDING_OUTPUT = 0
local BINDING_UNIFORM = 3
local BINDING_OCCLUSION_MAP = 4
local BINDING_LIGHT_GRID = 5
local SCREEN_SHADOW_TEXELS = 8
local SCREEN_SHADOW_MIN_REACH = 0.5
local SCREEN_SHADOW_MAX_REACH = 4
local SCREEN_SHADOW_MAX_STEPS = 24
local SCREEN_SHADOW_STRIDE = 1.5
pvars.StartGroup("lighting", {store = false})
local debug_direct = pvars.Setup2{
	key = "lighting_debug_direct",
	default = false,
	help = "show only the direct light",
}
pvars.EndGroup()
return {
	{
		name = "lighting",
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
				dst_stage = "fragment",
			},
		},
		storage_buffers = {{binding_index = BINDING_LIGHT_GRID}},
		on_pre_draw = function(self, cmd, frame, desc)
			light_occlusion.Draw(cmd)
			light_grid.Bind(self, cmd, desc, BINDING_LIGHT_GRID)
		end,
		sampled_images = {
			{
				binding_index = BINDING_OCCLUSION_MAP,
				get_texture = function()
					return light_occlusion.GetOcclusionTexture()
				end,
			},
		},
		uniform_buffers = {
			{
				name = "lighting_data",
				binding_index = BINDING_UNIFORM,
				block = {
					surface_lighting.block,
					gbuffer_layout.block,
					surface_weather.rain_surface_block,
					render3d.last_frame_block,
					{"gi_debug", "int"},
					{"direct_debug", "int"},
					{"ssr_tex", "int"},
					{"ambient_occlusion_tex", "int"},
					{"gi_overlay_tex", "int"},
					{"sky_clouds", "int"},
					{"noise_frame", "int"},
				},
				write = function(self, block)
					surface_lighting.WriteBlock(self, block)
					gbuffer_layout.WriteBlock(self, block)
					surface_weather.WriteRainSurfaceBlock(self, block)
					render3d.WriteLastFrameBlock(self, block)
					block.gi_debug = ddgi.IsDebugGI() and 1 or 0
					block.direct_debug = debug_direct:Get() and 1 or 0
					block.sky_clouds = render3d.GetActiveRenderContext() and 1 or 0
					block.noise_frame = render3d.IsPassEnabled("taa") and system.GetFrameNumber() % 16 or 0

					if render3d.IsPassEnabled("ambient_occlusion") then
						block.ambient_occlusion_tex = self:GetTextureIndex(render3d.pipelines.ambient_occlusion_blur:GetFramebuffer(1):GetAttachment(1))
					else
						block.ambient_occlusion_tex = -1
					end

					local overlay = ddgi.GetDebugOverlayTexture()
					block.gi_overlay_tex = overlay and self:GetTextureIndex(overlay) or -1

					if render3d.IsPassEnabled("ssr") then
						local current_idx = system.GetFrameNumber() % 2 + 1
						local current_ssr_fb = render3d.pipelines.ssr:GetFramebuffer(current_idx)
						block.ssr_tex = self:GetTextureIndex(current_ssr_fb:GetAttachment(1))
					else
						block.ssr_tex = -1
					end

					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_color;
			]] .. surface_lighting.GetDeclarationGLSL(BINDING_LIGHT_GRID, BINDING_OCCLUSION_MAP) .. [[
		]],
		shader = compute_helpers.GetScreenHelpersGLSL() .. [[
			vec2 get_compute_uv() {
				return get_screen_uv(get_screen_pos(), imageSize(out_color));
			}

			vec2 in_uv;

			void set_color(vec4 value) {
				if (lighting_data.gi_overlay_tex >= 0) {
					vec4 overlay = texture(TEXTURE(lighting_data.gi_overlay_tex), in_uv);
					value.rgb = mix(value.rgb, overlay.rgb, overlay.a);
				}

				imageStore(out_color, get_screen_pos(), value);
			}

			]] .. gbuffer_layout.GetDecodeGLSL("lighting_data") .. surface_weather.GetRainSurfaceGLSL("lighting_data") .. [[

			#define SHADOW_SCREEN_SPACE

			// marches the depth buffer from the surface towards the sun. what the gbuffer holds,
			// grass and other detail the shadow maps are too coarse for included, shadows it.
			// what is off screen doesn't
			float screen_space_shadow_visibility(vec3 world_pos, vec3 normal, vec3 light_dir, float texel_world_size) {
				float reach = clamp(texel_world_size * ]] .. string.format("%.1f", SCREEN_SHADOW_TEXELS) .. [[, ]] .. string.format("%.2f", SCREEN_SHADOW_MIN_REACH) .. [[, ]] .. string.format("%.2f", SCREEN_SHADOW_MAX_REACH) .. [[);
				vec3 start_vs = (lighting_data.view * vec4(world_pos, 1.0)).xyz;
				// off the surface by more than the depth reconstruction's error, which grows with distance
				start_vs += mat3(lighting_data.view) * normal * (0.004 + 0.001 * -start_vs.z);
				vec3 dir_vs = mat3(lighting_data.view) * light_dir;
				float ray_len = reach;

				if (start_vs.z + dir_vs.z * ray_len > -0.05) ray_len = (-0.05 - start_vs.z) / dir_vs.z;

				if (ray_len <= 1e-4) return 1.0;

				vec3 end_vs = start_vs + dir_vs * ray_len;
				vec4 h0 = lighting_data.projection * vec4(start_vs, 1.0);
				vec4 h1 = lighting_data.projection * vec4(end_vs, 1.0);
				float k0 = 1.0 / h0.w;
				float k1 = 1.0 / h1.w;
				vec2 p0 = h0.xy * k0 * 0.5 + 0.5;
				vec2 p1 = h1.xy * k1 * 0.5 + 0.5;
				float q0 = start_vs.z * k0;
				float q1 = end_vs.z * k1;
				ivec2 depth_size = textureSize(TEXTURE(lighting_data.depth_tex), 0);
				vec2 delta_px = (p1 - p0) * vec2(depth_size);
				int steps = clamp(int(max(abs(delta_px.x), abs(delta_px.y)) / ]] .. string.format("%.2f", SCREEN_SHADOW_STRIDE) .. [[), 2, ]] .. SCREEN_SHADOW_MAX_STEPS .. [[);
				float dt = 1.0 / float(steps);
				// interleaved gradient noise, moved on every frame while the taa is on, so it resolves the banding of the steps
				float jitter = fract(52.9829189 * fract(dot(gl_GlobalInvocationID.xy, vec2(0.06711056, 0.00583715))) + float(lighting_data.noise_frame) * 0.618034);
				float step_z = abs(dir_vs.z) * ray_len * dt;
				float depth_a = lighting_data.inv_projection[2][2];
				float depth_b = lighting_data.inv_projection[3][2];
				float depth_c = lighting_data.inv_projection[2][3];
				float depth_d = lighting_data.inv_projection[3][3];

				for (int i = 0; i < steps; i++) {
					float t = (float(i) + jitter) * dt;
					vec2 uv = mix(p0, p1, t);

					if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 1.0;

					float depth = texelFetch(TEXTURE(lighting_data.depth_tex), min(ivec2(uv * vec2(depth_size)), depth_size - 1), 0).r;

					if (depth >= 1.0) continue;

					float z_surf = (depth_a * depth + depth_b) / (depth_c * depth + depth_d);
					float z_ray = mix(q0, q1, t) / mix(k0, k1, t);
					float diff = z_surf - z_ray;
					float bias = 0.005 + 0.002 * -z_surf;
					float thickness = 0.05 + 0.005 * -z_surf + step_z;

					// fades out towards the end of the reach, so it doesn't end in an edge
					if (diff > bias && diff < thickness) return smoothstep(0.7, 1.0, t);
				}

				return 1.0;
			}

			]] .. surface_lighting.GetGLSL("lighting_data") .. [[

			]] .. ibl.GetReflectionGLSLCode("lighting_data") .. [[

			// ssr_uv is where the screen space reflection is read, moved off the pixel by what the ssr can't
			// resolve, like the rain's waves
			vec3 get_reflection(vec3 normal, float roughness, vec3 V, vec3 world_pos, float sky_visibility, vec3 gi_reflection_fallback, vec2 ssr_uv) {
				vec3 raw_R = reflect(-V, normal);
				vec3 R = get_specular_dominant_direction(raw_R, normal, roughness);
				vec3 sky_reflection = sample_environment_specular(lighting_data.env_tex, raw_R, normal, roughness);
				vec3 global_reflection = mix(gi_reflection_fallback, sky_reflection, sky_visibility);
				vec3 env_reflection = blend_probe_reflections(global_reflection, R, roughness, world_pos);

				if (lighting_data.ssr_tex == -1) return env_reflection;

				vec4 ssr = get_filtered_ssr_reflection(ssr_uv);
				return combine_reflections(env_reflection, ssr, get_ssr_blend_weight(roughness));
			}

			vec3 get_gi_irradiance(vec3 N, out float sky_visibility) {
				if (lighting_data.gi_screen_tex < 0) {
					sky_visibility = 1.0;
					return sample_environment_irradiance(lighting_data.env_irradiance_tex, N);
				}

				vec4 gi = texture(TEXTURE(lighting_data.gi_screen_tex), in_uv);
				sky_visibility = gi.a;
				return gi.rgb;
			}

			float get_ambient_occlusion(vec2 uv, vec3 world_pos, vec3 N) {
				if (lighting_data.ambient_occlusion_tex < 0) return 1.0;
				return texture(TEXTURE(lighting_data.ambient_occlusion_tex), uv).r;
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
				{clouds = "lighting_data.sky_clouds != 0"}
			) .. [[

				return max(sky_color_output, vec3(0.0));
			}

			vec3 get_indirect_light(vec3 F0, float NdotV, vec3 albedo, float roughness_alpha, float metallic, float transmission, vec3 transmission_color, vec3 world_pos, vec3 V, vec3 N, float clearcoat, float clearcoat_alpha, vec3 coat_smooth_N, vec3 coat_N)
			{
				float perceptual_roughness = sqrt(clamp(roughness_alpha, 0.0, 1.0));
				float sky_visibility;
				vec3 irradiance = get_gi_irradiance(N, sky_visibility);
				vec3 reflection = get_reflection(N, perceptual_roughness, V, world_pos, sky_visibility, irradiance, in_uv);
				float ambient_occlusion = get_ambient_occlusion(in_uv, world_pos, N) * gbuffer_ao(in_uv);

				vec3 F_ambient = F_SchlickRoughness(F0, NdotV, perceptual_roughness);
				vec3 kD_ambient = (1.0 - F_ambient) * (1.0 - metallic);
				vec3 ambient_diffuse = kD_ambient * irradiance * albedo * ambient_occlusion * (1.0 - transmission);

				if (transmission > 0.0) {
					// the gi only holds the light arriving at the front. the sky's part of it
					// is taken again from behind, and what bounced is assumed the same on
					// both sides
					vec3 front_sky = sample_environment_irradiance(lighting_data.env_irradiance_tex, N) * sky_visibility;
					vec3 back_sky = sample_environment_irradiance(lighting_data.env_irradiance_tex, -N) * sky_visibility;
					vec3 back_irradiance = back_sky + max(irradiance - front_sky, vec3(0.0));
					ambient_diffuse += transmission * transmission_color * albedo * (1.0 - metallic) * back_irradiance * ambient_occlusion;
				}

				vec2 envBRDF = texture(TEXTURE(lighting_data.brdf_lut_tex), vec2(NdotV, perceptual_roughness)).rg;

				vec3 ambient_specular = reflection * (F0 * envBRDF.x + F90(F0) * envBRDF.y);
				ambient_specular *= GGXEnergyCompensation(F0, envBRDF);
				ambient_specular *= SpecularOcclusion(NdotV, ambient_occlusion, perceptual_roughness);

				if (clearcoat > 0.0) {
					// the coat reflects its share, the rest goes through to the surface and back out
					float coat_NdotV = max(dot(coat_N, V), 0.001);
					float coat_roughness = sqrt(clamp(clearcoat_alpha, 0.0, 1.0));
					float Fc = F_SchlickScalar(CLEARCOAT_F0, coat_NdotV) * clearcoat;
					// the ssr traced the flat film, the rain's waves bend what it found as they would bend the ray. by
					// their tilt on screen, less so further away where the rings are smaller
					vec3 tilt = mat3(lighting_data.view) * (coat_N - coat_smooth_N);
					vec2 ssr_uv = in_uv + vec2(tilt.x, -tilt.y) * (0.1 / max(length(lighting_data.camera_position.xyz - world_pos), 1.0));
					vec3 coat_reflection = get_reflection(coat_N, coat_roughness, V, world_pos, sky_visibility, irradiance, ssr_uv);
					return (ambient_diffuse + ambient_specular) * (1.0 - Fc) + coat_reflection * Fc * SpecularOcclusion(coat_NdotV, ambient_occlusion, coat_roughness);
				}

				return ambient_diffuse + ambient_specular;
			}


			]] .. screen_reconstruct.GetWorldPosGLSL("lighting_data") .. [[

			]] .. screen_reconstruct.GetWorldPosFromUVGLSL("lighting_data", {function_name = "get_world_pos_at"}) .. [[

			]] .. screen_reconstruct.GetGeometricNormalGLSL("lighting_data") .. [[

			vec3 get_view_normal(vec3 world_pos) {
				return normalize(lighting_data.camera_position.xyz - world_pos);
			}

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;
				in_uv = get_compute_uv();

				float depth = gbuffer_depth(in_uv);

				if (depth == 1.0) {
					set_color(vec4(min(get_sky() * get_pre_exposure(), vec3(65504.0)), 1.0));
					return;
				}

				float alpha = gbuffer_alpha(in_uv);

				if (alpha == 0.0) {
					set_color(vec4(0.0, 0.0, 0.0, 0.0));
					return;
				}

				vec3 world_pos = get_world_pos(depth);
				vec3 V = get_view_normal(world_pos);
				// a normal map can turn a pixel away from the camera; shading it
				// like that zeroes both the diffuse (fresnel -> 1) and the
				// specular (grazing brdf) terms and leaves a black rim
				vec3 N = bend_normal_to_view(gbuffer_normal(in_uv), V);


				vec3 albedo = gbuffer_albedo(in_uv);
				float metallic = gbuffer_metallic(in_uv);
				float roughness = gbuffer_roughness(in_uv);
				float perceptual_roughness = sqrt(clamp(roughness, 0.0, 1.0));
				float transmission = gbuffer_transmission(in_uv);
				vec3 transmission_color = gbuffer_transmission_color(in_uv);
				float transmission_scattering = gbuffer_transmission_scattering(in_uv);
				vec3 emissive = gbuffer_emissive(in_uv);
				vec3 F0 = mix(vec3(gbuffer_dielectric_f0(in_uv)), albedo, metallic);
				float NdotV = max(dot(N, V), 0.001);
				vec3 geometric_N = get_geometric_normal(ivec2(in_uv * vec2(textureSize(TEXTURE(lighting_data.depth_tex), 0))), world_pos, depth, V, N);
				float clearcoat = gbuffer_clearcoat(in_uv);
				float clearcoat_alpha = gbuffer_clearcoat_roughness(in_uv);
				vec3 coat_smooth_N = geometric_N;

				if (clearcoat > 0.0) coat_smooth_N = gbuffer_clearcoat_normal(in_uv);

				vec3 coat_N = coat_smooth_N;

				if (clearcoat > 0.0) {
					// meters a pixel covers on the surface. at a glancing angle it stretches along the view only,
					// across it the rings stay as sharp, so the mean of both
					float footprint = length(world_pos - lighting_data.camera_position.xyz) * 2.0 * lighting_data.inv_projection[1][1] / float(size.y) / sqrt(max(dot(geometric_N, V), 0.01));
					apply_rain_surface(world_pos, footprint, gbuffer_clearcoat_rain(in_uv), coat_N, clearcoat_alpha);
				}

				vec3 direct_specular;
				vec3 direct = get_direct_light(F0, NdotV, albedo, roughness, perceptual_roughness, metallic, transmission, transmission_color, transmission_scattering, world_pos, V, N, geometric_N, clearcoat, clearcoat_alpha, coat_N, direct_specular);
				direct += direct_specular;

				if (lighting_data.direct_debug != 0) {
					set_color(vec4(min(direct * get_pre_exposure(), vec3(65504.0)), 1.0));
					return;
				}

				vec3 indirect = get_indirect_light(F0, NdotV, albedo, roughness, metallic, transmission, transmission_color, world_pos, V, N, clearcoat, clearcoat_alpha, coat_smooth_N, coat_N);
				vec3 color = direct + indirect + emissive;

				if (lighting_data.gi_debug != 0) {
					float debug_sky_visibility;
					color = get_gi_irradiance(N, debug_sky_visibility);
				}

				set_color(vec4(min(color * get_pre_exposure(), vec3(65504.0)), alpha));
			}
		]],
	},
	{
		name = "lighting_albedo",
		fallback = true,
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
				dst_stage = "fragment",
			},
		},
		uniform_buffers = {
			{
				name = "fallback_data",
				binding_index = BINDING_UNIFORM,
				block = {
					gbuffer_layout.block,
					post_source.pre_exposure_block,
					{"unexposed_scale", "float"},
				},
				write = function(self, block)
					block.unexposed_scale = render.target:IsHDR() and 1 or post_source.UNEXPOSED_SDR_WHITE
					gbuffer_layout.WriteBlock(self, block)
					post_source.WritePreExposureBlock(self, block)
					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_color;
		]],
		shader = compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("fallback_data") .. post_source.GetPreExposureGLSL("fallback_data") .. [[
			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				vec2 uv = get_screen_uv(pos, size);

				// the background as bright as a mid grey surface, so the exposure doesn't chase a black frame
				// without the exposure pass (which is the blit pass) nothing scales the scene down
				float scale = fallback_data.pre_exposure_tex == -1 ? fallback_data.unexposed_scale : ]] .. string.format("%.1f", render3d.EMISSIVE_REFERENCE_LUMINANCE) .. [[ * get_pre_exposure();

				if (gbuffer_depth(uv) == 1.0) {
					imageStore(out_color, pos, vec4(vec3(0.5 * scale), 1.0));
					return;
				}

				float alpha = gbuffer_alpha(uv);
				vec3 color = (gbuffer_albedo(uv) + gbuffer_emissive(uv)) * scale;
				imageStore(out_color, pos, vec4(min(color, vec3(65504.0)), alpha));
			}
		]],
	},
}
