local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local caustics = import("goluwa/render3d/caustics.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local light_grid = import("goluwa/render3d/light_grid.lua")
local surface_lighting = import("goluwa/render3d/surface_lighting.lua")
local surface_features = import("goluwa/render3d/surface_features.lua")
local surface_weather = import("goluwa/render3d/surface_weather.lua")
local radiance_cache = import("goluwa/render3d/radiance_cache.lua")
local gi = import("goluwa/render3d/gi.lua")
local scene_hits = import("goluwa/render3d/scene_hits.lua")
local optical_rays = import("goluwa/render3d/optical_rays.lua")
local ray_materials = import("goluwa/render3d/scene/ray_materials.lua")
local fluid_volumes = import("goluwa/render3d/fluid_volumes.lua")
local fluid_volume_passes = import("goluwa/render3d/fluid_volume_passes.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local pvars = import("goluwa/cli/pvars.lua")
local quality = import("goluwa/render3d/quality.lua")
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local BINDING_OUTPUT = 0
local BINDING_OUTPUT_DIFFUSE = 1
local BINDING_UNIFORM = 3
local BINDING_OCCLUSION_MAP = 4
local BINDING_LIGHT_GRID = 5
local BINDING_RADIANCE_CACHE = 12
local SCENE_BINDINGS = {scene = 6, hit = 30, materials = 8}
local SCREEN_SHADOW_MAX_STEPS = 64
local SCREEN_SHADOW_STRIDE = 1.5
pvars.StartGroup("Lighting", "Lighting", {store = false, prefix = "lighting_"})
local debug_direct = pvars.Setup2{
	key = "lighting_debug_direct",
	default = false,
	help = "show only the direct light",
}
local debug_indirect = pvars.Setup2{
	key = "lighting_debug_indirect",
	default = false,
	help = "show only the indirect light as the lighting composes it: the gi times the diffuse response plus the reflection times the specular albedo (with r_aa dlss_rr this is what ray reconstruction denoises, see r_dlss_show_input for the input)",
}
local debug_reflections = pvars.Setup2{
	key = "lighting_debug_reflections",
	default = false,
	help = "shows the traced reflection the lighting reads (after the reflection pass's filter and history) instead of the lit scene, black where nothing was traced",
}
pvars.StartGroup(
	"Lighting",
	"Screen space shadows",
	{store = false, prefix = "screen_space_shadow_"}
)
local screen_shadows = pvars.Setup2{
	key = "screen_space_shadows",
	friendly = "enabled",
	default = true,
	help = "march the depth buffer towards each light for contact shadows",
}
local screen_shadow_length = pvars.Setup2{
	key = "screen_space_shadow_length",
	default = 4,
	min = 0.1,
	max = 50,
	help = "farthest a screen space shadow ray reaches, in meters",
}
local screen_shadow_steps = pvars.Setup2{
	key = "screen_space_shadow_steps",
	default = 16,
	integer = true,
	min = 2,
	max = SCREEN_SHADOW_MAX_STEPS,
	help = "most depth samples a screen space shadow ray takes",
}
local screen_shadows_debug = pvars.Setup2{
	key = "screen_space_shadows_debug",
	friendly = "debug",
	default = false,
	help = "show only what the screen space shadows darken, white is untouched",
}
pvars.EndGroup()
pvars.StartGroup("Lighting", "Reflections", {store = false, prefix = "reflection_"})
local rough_sky = pvars.Setup2{
	key = "reflection_rough_sky",
	default = 0.6,
	min = 0.3,
	max = 1.5,
	help = "perceptual roughness above which a surface's ambient reflection is the probes' light and no raw sky (the sky fades out from 0.25), a rough surface's reflection is a blur of the gi, which already holds the sky. raise it to push the fade out towards rough surfaces only",
}
pvars.EndGroup()
pvars.StartGroup("Lighting", "Lighting", {store = false, prefix = "lighting_"})
local thin_specular = pvars.Setup2{
	key = "thin_specular",
	default = 1,
	min = 0,
	max = 1,
	help = "share of the ambient reflection a pixel less than two pixels wide keeps (1 is off). such a pixel, a glossy step seen at a grazing angle for one, is a bright line that appears and vanishes with the jitter",
}
pvars.EndGroup()
return {
	{
		name = "lighting",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"color", "rgba"}},
			{"r16g16b16a16_sfloat", {"subsurface_diffuse", "rgba"}},
		},
		framebuffer_count = 1,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = BINDING_OUTPUT,
				attachment = 1,
				dst_stage = "fragment",
			},
			{
				binding_index = BINDING_OUTPUT_DIFFUSE,
				attachment = 2,
				dst_stage = "compute",
			},
		},
		storage_buffers = {
			{binding_index = BINDING_LIGHT_GRID},
			{binding_index = fluid_volume_passes.BINDING_RECORDS},
		},
		descriptor_sets = optical_rays.RAY_QUERY and
			scene_hits.GetDescriptorSets(SCENE_BINDINGS, "compute") or
			nil,
		on_pre_draw = function(self, cmd, frame, desc)
			if not render3d.AreLightsOverridden() then light_occlusion.Draw(cmd) end

			light_grid.Bind(self, cmd, desc, BINDING_LIGHT_GRID)
			fluid_volume_passes.BindRecords(self, desc)

			if optical_rays.RAY_QUERY then
				scene_hits.Bind(self, cmd, desc, SCENE_BINDINGS)
			end
		end,
		sampled_images = {
			{
				binding_index = BINDING_OCCLUSION_MAP,
				get_texture = function()
					return light_occlusion.GetOcclusionTexture()
				end,
			},
			unpack(fluid_volume_passes.GetSampledImages()),
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
					{"indirect_debug", "int"},
					{"reflection_debug", "int"},
					{"ambient_occlusion_tex", "int"},
					{"gi_overlay_tex", "int"},
					{"sky_clouds", "int"},
					{"sky_air", "int"},
					{"sky_alpha", "float"},
					{"sky_from_environment", "int"},
					{"screen_shadows", "int"},
					{"screen_shadows_debug", "int"},
					{"screen_shadow_length", "float"},
					{"screen_shadow_steps", "int"},
					{"thin_specular", "float"},
					{"rough_sky", "float"},
					{"gi_per_pixel", "int"},
					{"caustics_tex", "int"},
				},
				write = function(self, block)
					surface_lighting.WriteBlock(self, block)
					gbuffer_layout.WriteBlock(self, block)
					surface_weather.WriteRainSurfaceBlock(self, block)
					render3d.WriteLastFrameBlock(self, block)
					block.gi_debug = gi.IsDebugGI() and 1 or 0
					block.direct_debug = debug_direct:Get() and 1 or 0
					block.indirect_debug = debug_indirect:Get() and 1 or 0
					block.reflection_debug = debug_reflections:Get() and 1 or 0
					block.sky_clouds = render3d.GetActiveRenderContext() and 1 or 0
					block.sky_air = (
							render3d.GetActiveRenderContext() or
							not render3d.IsPassEnabled("volumetric_fog")
						)
						and
						1 or
						0
					block.sky_alpha = render3d.IsSkyTransparent() and 0 or 1
					block.sky_from_environment = render3d.IsSkyFromProbe() and 1 or 0
					block.screen_shadows = screen_shadows:Get() and quality.Get().screen_shadow_step_scale > 0 and 1 or 0
					block.screen_shadows_debug = screen_shadows_debug:Get() and 1 or 0
					block.screen_shadow_length = screen_shadow_length:Get() * render3d.GetViewScale()
					block.screen_shadow_steps = math.max(math.floor(screen_shadow_steps:Get() * quality.Get().screen_shadow_step_scale), 2)
					block.thin_specular = thin_specular:Get()
					block.rough_sky = rough_sky:Get()
					block.gi_per_pixel = gi.IsPerPixel() and 1 or 0

					if render3d.IsPassEnabled("ambient_occlusion") then
						block.ambient_occlusion_tex = self:GetTextureIndex(render3d.pipelines.ambient_occlusion_blur:GetFramebuffer(1):GetAttachment(1))
					else
						block.ambient_occlusion_tex = -1
					end

					if caustics.IsLit() then
						block.caustics = 1
						block.caustics_tex = self:GetTextureIndex(render3d.pipelines.caustics:GetFramebuffer(system.GetFrameNumber() % 2 + 1):GetAttachment(1))
					else
						block.caustics_tex = -1
					end

					if render3d.IsPassEnabled("ray_shadows") and not render3d.IsDenoisingBypassed() then
						block.ray_shadow_tex = self:GetTextureIndex(render3d.pipelines.ray_shadow_filter:GetFramebuffer(1):GetAttachment(1))
					end

					local overlay = gi.GetDebugOverlayTexture()
					block.gi_overlay_tex = overlay and self:GetTextureIndex(overlay) or -1
					return block
				end,
			},
			scene_hits.GetRadianceCacheUniformBuffer(BINDING_RADIANCE_CACHE),
		},
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_color;
			layout(set = 0, binding = ]] .. BINDING_OUTPUT_DIFFUSE .. [[, rgba16f) uniform writeonly image2D out_subsurface_diffuse;
			]] .. surface_lighting.GetDeclarationGLSL(BINDING_LIGHT_GRID, BINDING_OCCLUSION_MAP) .. fluid_volume_passes.GetDeclarationGLSL() .. (
				optical_rays.RAY_QUERY and
				optical_rays.GetDeclarationGLSL(SCENE_BINDINGS) or
				""
			) .. [[
		]],
		shader = compute_helpers.GetScreenHelpersGLSL() .. [[
			vec2 get_compute_uv() {
				return get_screen_uv(get_screen_pos(), imageSize(out_color));
			}

			vec2 in_uv;
			ivec2 in_pixel;
			float in_view_depth;

			vec4 subsurface_diffuse_out = vec4(0.0);
			vec3 indirect_diffuse_light = vec3(0.0);

			void set_color(vec4 value) {
				if (lighting_data.gi_overlay_tex >= 0) {
					vec4 overlay = texture(TEXTURE(lighting_data.gi_overlay_tex), in_uv);
					value.rgb = mix(value.rgb, overlay.rgb, overlay.a);
				}

				imageStore(out_color, get_screen_pos(), value);
				imageStore(out_subsurface_diffuse, get_screen_pos(), subsurface_diffuse_out);
			}

			]] .. gbuffer_layout.GetDecodeGLSL("lighting_data") .. surface_weather.GetRainSurfaceGLSL("lighting_data") .. [[

			#define SHADOW_SCREEN_SPACE

			float screen_shadow_term = 1.0;

			float screen_space_shadow_visibility(vec3 world_pos, vec3 normal, vec3 light_dir, float reach, bool reach_is_light) {
				float view_scale = lighting_data.view_scale;
				vec3 start_vs = (lighting_data.view * vec4(world_pos, 1.0)).xyz;
				float view_fade = 1.0 - smoothstep(60.0 * view_scale, 120.0 * view_scale, -start_vs.z);

				if (view_fade <= 0.0) return 1.0;

				start_vs += mat3(lighting_data.view) * normal * (0.004 * view_scale + 0.001 * -start_vs.z);
				vec3 dir_vs = mat3(lighting_data.view) * light_dir;
				float ray_len = reach;
				float end_fade_start = reach_is_light ? 1.0 : 0.7;

				if (start_vs.z + dir_vs.z * ray_len > -0.05 * view_scale) {
					ray_len = (-0.05 * view_scale - start_vs.z) / dir_vs.z;
					end_fade_start = 1.0;
				}

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
				int steps = clamp(int(max(abs(delta_px.x), abs(delta_px.y)) / ]] .. string.format("%.2f", SCREEN_SHADOW_STRIDE) .. [[), 2, lighting_data.screen_shadow_steps);
				float dt = 1.0 / float(steps);
				float jitter = fract(52.9829189 * fract(dot(gl_GlobalInvocationID.xy, vec2(0.06711056, 0.00583715))) + lighting_data.noise_phase);
				float step_z = abs(dir_vs.z) * ray_len * dt;
				float depth_a = lighting_data.inv_projection[2][2];
				float depth_b = lighting_data.inv_projection[3][2];
				float depth_c = lighting_data.inv_projection[2][3];
				float depth_d = lighting_data.inv_projection[3][3];
				float occlusion = 0.0;

				for (int i = 0; i < steps; i++) {
					float t = (float(i) + jitter) * dt;
					vec2 uv = mix(p0, p1, t);

					if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) break;

					float depth = texelFetch(TEXTURE(lighting_data.depth_tex), min(ivec2(uv * vec2(depth_size)), depth_size - 1), 0).r;

					if (depth <= 0.0) continue;

					float z_surf = (depth_a * depth + depth_b) / (depth_c * depth + depth_d);
					float z_ray = mix(q0, q1, t) / mix(k0, k1, t);
					float diff = z_surf - z_ray;
					float bias = 0.005 * view_scale + 0.002 * -z_surf;
					float thickness = 0.05 * view_scale + 0.005 * -z_surf + step_z;
					float coverage = smoothstep(bias, bias * 3.0 + step_z * 0.25, diff) * (1.0 - smoothstep(thickness * 0.6, thickness, diff));

					if (coverage > 0.0) {
						occlusion = max(occlusion, coverage * (1.0 - smoothstep(end_fade_start, 1.0001, t)));

						if (occlusion >= 0.99) break;
					}
				}

				return 1.0 - occlusion * view_fade;
			}

			]] .. (
				optical_rays.RAY_QUERY and
				optical_rays.GetGLSL() .. ray_materials.GetAlphaTestGLSL()
				or
				""
			) .. "#define FLUID_SHADOWS 1\n" .. fluid_volumes.GetGLSL() .. surface_lighting.GetGLSL("lighting_data", optical_rays.RAY_QUERY) .. radiance_cache.GetScreenSampleGLSL("lighting_data") .. radiance_cache.GetCommonGLSL() .. [[

			]] .. ibl.GetReflectionGLSLCode("lighting_data") .. [[

			// the radiance pass's traced specular already holds the sky and the occluders, without it a reflection is the environment and the probes' light
			vec3 get_reflection(vec3 normal, float roughness, vec3 V, vec3 world_pos, float sky_visibility, vec3 gi_reflection, float specular_occlusion) {
				if (lighting_data.gi_screen_specular_tex >= 0) return gi_reflection;

				vec3 raw_R = reflect(-V, normal);
				vec3 R = get_specular_dominant_direction(raw_R, normal, roughness);
				vec3 sky_reflection = sample_environment_specular(lighting_data.env_tex, raw_R, normal, roughness);
				float sky_weight = sky_visibility * (1.0 - smoothstep(0.25, max(lighting_data.rough_sky, 0.26), roughness));
				vec3 global_reflection = mix(gi_reflection, sky_reflection, sky_weight);
				return blend_probe_reflections(global_reflection, R, roughness, world_pos) * specular_occlusion;
			}

			vec3 get_gi_irradiance(vec3 N, out float sky_visibility) {
				if (lighting_data.gi_screen_tex < 0) {
					sky_visibility = 1.0;
					return sample_environment_irradiance(lighting_data.env_irradiance_tex, N);
				}

				vec4 gi = radiance_cache_screen_sample(in_uv, N, in_view_depth);
				sky_visibility = gi.a;
				return gi.rgb;
			}

			vec3 grade_indirect_diffuse(vec3 irradiance) {
				float grey = luminance(irradiance);

				if (grey <= 0.0) return irradiance;

				irradiance = max(vec3(grey) + (irradiance - grey) * lighting_data.gi_saturation, vec3(0.0));
				return irradiance * lighting_data.gi_gain * pow(grey * get_exposure() / lighting_data.gi_contrast_pivot, lighting_data.gi_contrast - 1.0);
			}

			vec4 get_ambient_occlusion(vec2 uv) {
				if (lighting_data.ambient_occlusion_tex < 0) return vec4(0.0, 0.0, 0.0, 1.0);
				return texture(TEXTURE(lighting_data.ambient_occlusion_tex), uv);
			}

			vec3 get_sky_dir(vec2 uv) {
				vec4 view_pos = lighting_data.inv_projection * vec4(uv * 2.0 - 1.0, 1.0, 1.0);
				return normalize(mat3(lighting_data.inv_view) * (view_pos.xyz / view_pos.w));
			}

			vec3 get_sky() {
				vec3 sky_dir = get_sky_dir(in_uv);
				vec2 sky_texel = 1.0 / vec2(imageSize(out_color));
				vec3 sky_dir_dx = get_sky_dir(in_uv + vec2(sky_texel.x, 0.0)) - sky_dir;
				vec3 sky_dir_dy = get_sky_dir(in_uv + vec2(0.0, sky_texel.y)) - sky_dir;
				vec3 sun_dir = get_primary_sun_direction();
				vec3 sky_color_output = vec3(0.0);

				if (lighting_data.sky_from_environment != 0) {
					return sample_environment_specular(lighting_data.env_tex, sky_dir, sky_dir, 0.0);
				}

				]] .. atmosphere.GetGLSLMainCode(
				"sky_dir",
				"sun_dir",
				"lighting_data.camera_position.xyz",
				{
					clouds = "lighting_data.sky_clouds != 0",
					air = "lighting_data.sky_air != 0",
					dir_dx = "sky_dir_dx",
					dir_dy = "sky_dir_dy",
				}
			) .. [[

				return max(sky_color_output, vec3(0.0));
			}

			]] .. surface_features.GetDecodeFunctionGLSL() .. [[

			float get_thin_feature(float view_depth, vec3 N) {
				ivec2 size = textureSize(TEXTURE(lighting_data.depth_tex), 0);
				float thin = 0.0;

				for (int axis = 0; axis < 2; axis++) {
					ivec2 step_pixel = axis == 0 ? ivec2(1, 0) : ivec2(0, 1);
					bool differs[2];

					for (int side = 0; side < 2; side++) {
						ivec2 p = clamp(in_pixel + step_pixel * (side == 0 ? -1 : 1), ivec2(0), size - 1);
						float d = gbuffer_depth(p);
						float neighbour_depth = d <= 0.0 ? 1e6 : -(lighting_data.inv_projection[2][2] * d + lighting_data.inv_projection[3][2]) / (lighting_data.inv_projection[2][3] * d + lighting_data.inv_projection[3][3]);
						differs[side] = abs(neighbour_depth - view_depth) > view_depth * 0.03 || dot(N, gbuffer_normal(p)) < 0.9;
					}

					if (differs[0] && differs[1]) thin = 1.0;
				}

				return thin;
			}

			vec3 get_caustic_light_direction(vec3 P, vec3 N) {
				vec3 sum = vec3(0.0);
				vec2 uv = vec2(dot(P, lighting_data.caustic_sun_u.xyz), dot(P, lighting_data.caustic_sun_v.xyz));

				for (int k = 0; k < lighting_data.caustic_caster_count; k++) {
					vec4 meta = lighting_data.caustic_rects[k * 2 + 1];
					vec4 rect = lighting_data.caustic_rects[k * 2];
					lights_t light = lighting_data.lights[int(meta.z)];
					vec3 L;
					float attenuation;

					float inside;

					if (meta.w > 0.5) {
						float angle = acos(clamp(rect.w, -1.0, 1.0));
						inside = smoothstep(cos(min(angle * 2.0 + 0.3, 3.14159265359)), rect.w, dot(normalize(P - light.position.xyz), rect.xyz));
					} else {
						vec2 outside = max(max(rect.xy - uv, uv - rect.zw), vec2(0.0));
						inside = 1.0 - smoothstep(0.0, 0.5 * max(rect.z - rect.x, rect.w - rect.y), length(outside));
					}

					if (inside <= 0.0 || !get_light_vector_and_attenuation(light, P, L, attenuation) || dot(L, N) <= 0.0) continue;

					sum += L * luminance(light.color.rgb) * light.color.a * attenuation * inside;
				}

				return dot(sum, sum) > 0.0 ? normalize(sum) : N;
			}

			vec3 get_indirect_light(in Surface s)
			{
				float sky_visibility;
				vec3 irradiance = get_gi_irradiance(s.N, sky_visibility);
				vec3 reflection_gi = irradiance;

				if (lighting_data.gi_screen_specular_tex >= 0) reflection_gi = radiance_cache_screen_specular_sample(in_uv, s.N, in_view_depth, s.perceptual_roughness).rgb / get_pre_exposure();
				
				vec4 screen_gi = get_ambient_occlusion(in_uv);
				float ambient_occlusion = screen_gi.a;
				vec3 reflection = get_reflection(s.N, s.perceptual_roughness, s.V, s.world_pos, sky_visibility, reflection_gi, SpecularOcclusion(s.NdotV, ambient_occlusion, s.perceptual_roughness));
				vec3 sky_light = get_sky_light_from(s.world_pos, lighting_data.env_position.xyz);
				irradiance *= sky_light;
				reflection *= sky_light;
				vec3 bounce = screen_gi.rgb / get_pre_exposure();

				vec4 brdf_lut = texture(TEXTURE(lighting_data.brdf_lut_tex), vec2(s.NdotV, s.perceptual_roughness));
				vec2 envBRDF = brdf_lut.rg;
				vec3 specular_albedo = (s.F0 * envBRDF.x + F90(s.F0) * envBRDF.y) * GGXEnergyCompensation(s.F0, envBRDF);
				vec3 kD_ambient = max(1.0 - specular_albedo, vec3(0.0)) * (1.0 - s.metallic);
				vec3 ambient_diffuse = kD_ambient * grade_indirect_diffuse(lighting_data.gi_per_pixel != 0 ? irradiance : irradiance * ambient_occlusion + bounce) * EON_directional_albedo(s.albedo, s.diffuse_roughness, s.NdotV);

				vec3 caustic_specular = vec3(0.0);

				if (lighting_data.caustics_tex >= 0) {
					vec3 caustic = texelFetch(TEXTURE(lighting_data.caustics_tex), in_pixel, 0).rgb / get_pre_exposure();

					if (caustic.r + caustic.g + caustic.b > 0.0) {
						// photons keep no direction, they shade as light from about the lights whose photons cover the pixel
						vec3 L = get_caustic_light_direction(s.world_pos, s.N);
						L = normalize(L + s.N * max(0.1 - dot(s.N, L), 0.0));
						float NoL = saturate(dot(s.N, L));
						vec3 H = normalize(s.V + L);
						ambient_diffuse += Fd_EON(s.albedo, s.diffuse_roughness, NoL, s.NdotV, dot(L, s.V)) * kD_ambient * GGXDiffuseCoupling(s.F0, texture(TEXTURE(lighting_data.brdf_lut_tex), vec2(NoL, s.perceptual_roughness)).rg, brdf_lut.ba) * caustic;
						caustic_specular = D_GGXAlpha(s.roughness_alpha, saturate(dot(s.N, H))) * V_SmithGGXCorrelated(s.roughness_alpha, s.NdotV, NoL) * F_Surface(s.F0, 0.04 * s.specular, s.metallic, saturate(dot(L, H))) * GGXEnergyCompensation(s.F0, envBRDF) * caustic;
					}
				}

				vec3 ambient_specular = reflection * specular_albedo + caustic_specular;
				ambient_specular *= mix(1.0, lighting_data.thin_specular, get_thin_feature(in_view_depth, s.geometric_N));

				]] .. surface_features.GetIndirectGLSL() .. [[

				]] .. surface_features.GetIndirectLayerGLSL() .. [[

				indirect_diffuse_light = ambient_diffuse;

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
				in_pixel = pos;
				]] .. (
				optical_rays.RAY_QUERY and
				"ray_shadow_pixel = pos;" or
				""
			) .. [[

				float depth = gbuffer_depth(in_uv);

				if (depth == 0.0) {
					set_color(vec4(min(get_sky() * get_pre_exposure(), vec3(65504.0)), lighting_data.sky_alpha));
					return;
				}

				float alpha = gbuffer_alpha(in_uv);

				if (alpha == 0.0) {
					set_color(vec4(0.0, 0.0, 0.0, 0.0));
					return;
				}

				in_view_depth = -(lighting_data.inv_projection[2][2] * depth + lighting_data.inv_projection[3][2]) / (lighting_data.inv_projection[2][3] * depth + lighting_data.inv_projection[3][3]);
				vec3 world_pos = get_world_pos(depth);
				vec3 V = get_view_normal(world_pos);
				vec3 N = bend_normal_to_view(gbuffer_normal(in_uv), V);


				float NdotV = max(dot(N, V), 0.001);
				vec3 geometric_N = get_geometric_normal(ivec2(in_uv * vec2(textureSize(TEXTURE(lighting_data.depth_tex), 0))), world_pos, depth, V);

				Surface surface;
				surface.NdotV = NdotV;
				surface.world_pos = world_pos;
				surface.V = V;
				surface.N = N;
				surface.geometric_N = geometric_N;
				decode_surface_features(surface, in_uv, size);
				finish_surface_features(surface);

				vec3 direct_specular;
				screen_shadow_term = 1.0;
				vec3 direct_diffuse = get_direct_light(surface, direct_specular);
				vec3 direct = direct_diffuse + direct_specular;

				if (lighting_data.screen_shadows_debug != 0) {
					set_color(vec4(vec3(screen_shadow_term * 0.1 * lighting_data.primary_sun_illuminance * get_pre_exposure()), 1.0));
					return;
				}

				if (lighting_data.direct_debug != 0) {
					set_color(vec4(min(direct * get_pre_exposure(), vec3(65504.0)), 1.0));
					return;
				}

				vec3 indirect = get_indirect_light(surface);

				if (lighting_data.indirect_debug != 0) {
					set_color(vec4(min(indirect * get_pre_exposure(), vec3(65504.0)), 1.0));
					return;
				}
				vec3 color = direct + indirect + surface.emissive;

				{
					Surface s = surface;
					vec3 compose_color = color;
					]] .. surface_features.GetComposeGLSL() .. [[
					color = compose_color;
				}

				if (surface.subsurface > 0.0) {
					vec3 diffuse_albedo = max(surface.albedo, vec3(]] .. string.format("%.3f", render3d.SUBSURFACE_MIN_ALBEDO) .. [[));
					subsurface_diffuse_out = vec4(min((direct_diffuse + indirect_diffuse_light) * get_pre_exposure() / diffuse_albedo, vec3(65504.0)), surface.subsurface);
				}

				if (lighting_data.gi_debug != 0) {
					float debug_sky_visibility;
					color = get_gi_irradiance(N, debug_sky_visibility);
				}

				if (lighting_data.reflection_debug != 0) {
					color = radiance_cache_screen_specular_sample(in_uv, N, in_view_depth, surface.perceptual_roughness).rgb / get_pre_exposure();
				}

				set_color(vec4(min(color * get_pre_exposure(), vec3(65504.0)), alpha));
			}
		]],
	},
	{
		name = "lighting_albedo",
		lazy_framebuffers = true,
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
					block.unexposed_scale = post_source.UNEXPOSED_SDR_WHITE
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

				float scale = fallback_data.pre_exposure_tex == -1 ? fallback_data.unexposed_scale : ]] .. string.format("%.1f", render3d.EMISSIVE_REFERENCE_LUMINANCE) .. [[ * get_pre_exposure();

				if (gbuffer_depth(uv) == 0.0) {
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
