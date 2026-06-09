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
local ibl = import("goluwa/render3d/ibl.lua")
local get_primary_sun = directional_shadows.GetPrimarySun
local get_primary_sun_direction = directional_shadows.GetPrimarySunDirection
local get_primary_sun_intensity = directional_shadows.GetPrimarySunIntensity
local MAX_LIGHTS = scene_lights.MAX_LIGHTS
local MAX_CASCADES = scene_lights.MAX_CASCADES
local MAX_POINT_SHADOWS = scene_lights.MAX_POINT_SHADOWS
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}

local function sort_lights(a, b)
	if a.last_update_frame ~= b.last_update_frame then
		return a.last_update_frame > b.last_update_frame
	end

	if a.distance_score ~= b.distance_score then
		return a.distance_score < b.distance_score
	end

	return a.light_index < b.light_index
end

local function write_shadow_block(self, shadow_block, lights)
	return scene_lights.WriteShadowBlock(self, shadow_block, lights)
end

local function write_lights_block(lights_block, lights)
	return scene_lights.WriteLightsBlock(lights_block, lights)
end

local function resolve_lighting_frame_index(self, frame_index)
	local descriptor_set_count = self.pipeline.descriptor_sets and #self.pipeline.descriptor_sets or 0

	if descriptor_set_count > 0 then
		return math.clamp(render.GetCurrentFrame() or frame_index or 1, 1, descriptor_set_count)
	end

	if frame_index then return frame_index end

	if self.framebuffers and #self.framebuffers > 0 then
		return system.GetFrameNumber() % #self.framebuffers + 1
	end

	return 1
end

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
					{"lights", scene_lights.BuildLightsBlockLayout(), 128},
					{"light_count", "int"},
					{"shadows", scene_lights.BuildShadowsBlockLayout()},
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
					{"probe_irradiance_tex", "int"},
					{"voxel_irradiance_tex", "int"},
					{"ssr_tex", "int"},
					{"ambient_occlusion_tex", "int"},
					{"ssgi_tex", "int"},
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					local lights = render3d.GetLights()
					local light_count = math.min(#lights, MAX_LIGHTS)
					block.light_count = light_count
					write_lights_block(block.lights, lights)
					write_shadow_block(self, block.shadows, lights)
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

					if render3d.pipelines.probe_irradiance then
						block.probe_irradiance_tex = self:GetTextureIndex(render3d.pipelines.probe_irradiance:GetFramebuffer(1):GetAttachment(1))
					end

					if render3d.pipelines.ambient_occlusion then
						block.ambient_occlusion_tex = self:GetTextureIndex(render3d.pipelines.ambient_occlusion:GetFramebuffer(1):GetAttachment(1))
					end

					if not render3d.pipelines.ssr or not render3d.pipelines.ssr.framebuffers then
						block.ssr_tex = -1
					else
						local current_idx = system.GetFrameNumber() % 2 + 1
						local current_ssr_fb = render3d.pipelines.ssr:GetFramebuffer(current_idx)
						block.ssr_tex = self:GetTextureIndex(current_ssr_fb:GetAttachment(1))
					end

					if render3d.pipelines.ssgi then
						block.ssgi_tex = self:GetTextureIndex(render3d.pipelines.ssgi_filter_2:GetFramebuffer(1):GetAttachment(1))
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

			vec3 get_reflection(vec3 normal, float roughness, vec3 V, vec3 world_pos) {
				if (lighting_data.ssr_tex == -1) {
					vec3 raw_R = reflect(-V, normal);
					return sample_environment_specular(lighting_data.env_tex, raw_R, normal, roughness);
				}

				vec4 ssr = get_filtered_ssr_reflection(in_uv);
				return ssr.rgb;
			}

			vec3 get_ssgi_irradiance(float roughness) {
				if (lighting_data.ssgi_tex == -1) {
					return vec3(1.0);
				}
				// Sample from SSGI mip chain based on roughness
				// Rougher surfaces get more blurred (lower mip levels)
				float max_mip = 5.0;
				float lod = roughness * roughness * max_mip;
				lod = clamp(lod, 0.0, max_mip);
				return textureLod(TEXTURE(lighting_data.ssgi_tex), in_uv, lod).rgb;
			}

			float get_ssgi_confidence(float roughness) {
				if (lighting_data.ssgi_tex == -1) {
					return 0.0;
				}
				// Use same LOD as get_ssgi_irradiance for consistency
				float max_mip = 5.0;
				float lod = roughness * roughness * max_mip;
				lod = clamp(lod, 0.0, max_mip);
				return textureLod(TEXTURE(lighting_data.ssgi_tex), in_uv, lod).a;
			}

			vec3 get_probe_irradiance() {
				if (lighting_data.probe_irradiance_tex == -1) {
					return vec3(1.0);
				}
				return texture(TEXTURE(lighting_data.probe_irradiance_tex), in_uv).rgb;
			}

			float get_ambient_occlusion(vec2 uv, vec3 world_pos, vec3 N) {
				return texture(TEXTURE(lighting_data.ambient_occlusion_tex), uv).r;
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

			vec3 subsurface_shading_back(vec3 eye_dir, vec3 light_dir, vec3 normal, vec3 transmission_color, float view_dependency)
			{
				float backlit = saturate(dot(-normal, light_dir));
				float eye_dot_light = saturate(dot(eye_dir, -light_dir));
				float eye_dot_light_pow = eye_dot_light * eye_dot_light;
				eye_dot_light_pow *= eye_dot_light_pow;
				float focused_backlit = backlit * backlit;
				float back_wrap = smoothstep(0.45, 0.95, backlit);
				back_wrap *= back_wrap;
				float back_shading = mix(eye_dot_light_pow * focused_backlit, back_wrap, view_dependency);
				return back_shading * transmission_color;
			}

			float get_transmission_blocking_detail(float transmission_blocking)
			{
				return saturate(transmission_blocking + 0.25);
			}

			void subsurface_shading_front(vec3 eye_dir, vec3 light_dir, vec3 normal, vec3 diffuse_color, vec3 specular_color, float gloss_power, out vec3 out_diffuse, out vec3 out_specular)
			{
				float light_dot_normal = saturate(dot(normal, light_dir));
				vec3 reflected_light = reflect(-light_dir, normal);
				float specular = pow(saturate(dot(reflected_light, eye_dir)), gloss_power);
				float wrapped_diffuse = saturate(light_dot_normal * 0.7 + 0.3);
				out_diffuse = wrapped_diffuse * diffuse_color;
				out_specular = specular * specular_color;
			}

			vec3 get_direct_light(vec3 F0, float NdotV, vec3 albedo, float roughness_alpha, float perceptual_roughness, float metallic, float subsurface, float transmission_blocking, vec3 transmission_color, float transmission_view_dependency, vec3 world_pos, vec3 V, vec3 N)
			{
				vec3 Lo = vec3(0.0);
				float subsurface_factor = subsurface;

                for (int i = 0; i < lighting_data.light_count; i++) {
                    lights_t light = lighting_data.lights[i];
					int type = get_light_type(light);
					vec3 L;
					float attenuation = 1.0;
					if (!get_light_vector_and_attenuation(light, world_pos, L, attenuation)) {
						continue;
					}
                    vec3 H = normalize(V + L);
                    float NoL = saturate(dot(N, L));
                    float NoH = saturate(dot(N, H));
                    float LoH = saturate(dot(L, H));

					float D = D_GGXAlpha(roughness_alpha, NoH);
					float V_func = V_SmithGGXCorrelated(roughness_alpha, NdotV, NoL);
                    vec3 F = F_Schlick(F0, LoH);

					vec3 Fr = (D * V_func) * F;
					vec3 kD = (1.0 - F) * (1.0 - metallic);
					vec3 Fd = kD * albedo * Fd_Burley(NoL, NdotV, LoH, perceptual_roughness);

                    float shadow_factor = 1.0;
					if (
						i == lighting_data.shadows.directional_shadow_light_index &&
						lighting_data.shadows.shadow_map_indices[0] >= 0 &&
						type == 0
					) {
                        shadow_factor = calculateShadow(world_pos, N, L);
					} else if (
						i == lighting_data.shadows.local_directional_shadow_light_index &&
						lighting_data.shadows.local_directional_shadow_map_index >= 0 &&
						type == 2
					) {
						shadow_factor = calculateLocalDirectionalShadow(world_pos, N, L);
					} else if (type == 1) {
						int point_shadow_slot = getPointShadowSlot(i);
						if (point_shadow_slot >= 0) {
							shadow_factor = calculatePointShadow(point_shadow_slot, world_pos, N, L);
						}
                    }
                    vec3 radiance = light.color.rgb * light.color.a * attenuation;
					vec3 transmission = vec3(0.0);
					vec3 subsurface_front = vec3(0.0);
					vec3 subsurface_spec = vec3(0.0);

					if (subsurface > 0.0) {
						float subsurface_gloss = mix(6.0, 24.0, 1.0 - roughness_alpha);
						float blocking_detail = get_transmission_blocking_detail(transmission_blocking);
						float transmission_amount = 1.0 - blocking_detail;
						float front_amount = blocking_detail;
						vec3 transmission_tint = mix(transmission_color, transmission_color * albedo, blocking_detail);
						vec3 front_diffuse = vec3(0.0);
						vec3 front_specular = vec3(0.0);
						vec3 subsurface_specular_color = mix(vec3(0.01), albedo * 0.035, 0.5);
						subsurface_shading_front(V, L, N, light.color.rgb, subsurface_specular_color, subsurface_gloss, front_diffuse, front_specular);
						transmission = subsurface_shading_back(V, L, N, transmission_tint, transmission_view_dependency) * transmission_amount * radiance * shadow_factor * 1.2;
						subsurface_front = front_diffuse * albedo * radiance * shadow_factor * front_amount;
						subsurface_spec = front_specular * radiance * shadow_factor * 0.35 * front_amount;
					}

					vec3 pbr_light = (Fd + Fr) * radiance * NoL * shadow_factor;
					vec3 subsurface_light = subsurface_front + subsurface_spec + transmission;
					Lo += mix(pbr_light, subsurface_light, subsurface_factor);
                }

				return Lo;				
			}

			vec3 get_indirect_light(vec3 F0, float NdotV, vec3 albedo, float roughness_alpha, float metallic, float subsurface, float transmission_blocking, vec3 transmission_color, float transmission_view_dependency, vec3 world_pos, vec3 V, vec3 N)
			{
				float subsurface_factor = subsurface;
				float blocking_detail = get_transmission_blocking_detail(transmission_blocking);
				float transmission_amount = 1.0 - blocking_detail;
				float perceptual_roughness = sqrt(clamp(roughness_alpha, 0.0, 1.0));
				vec3 reflection = get_reflection(N, perceptual_roughness, V, world_pos);
				float ambient_front_amount = blocking_detail;
				vec3 ambient_transmission_tint = mix(vec3(1.0), transmission_color * albedo, blocking_detail);
				float ambient_occlusion = get_ambient_occlusion(in_uv, world_pos, N);

				vec3 irradiance = mix(get_probe_irradiance(), get_ssgi_irradiance(perceptual_roughness), get_ssgi_confidence(perceptual_roughness));

				vec3 back_irradiance = irradiance;
				vec3 F_ambient = F_SchlickRoughness(F0, NdotV, perceptual_roughness);
				vec3 kD_ambient = (1.0 - F_ambient) * (1.0 - metallic);
				vec3 ambient_diffuse = kD_ambient * irradiance * albedo * ambient_occlusion;
				ambient_diffuse *= mix(1.0, ambient_front_amount, subsurface_factor);
				float hemi = saturate(N.y * 0.5 + 0.5);
				vec3 subsurface_ambient = mix(ambient_diffuse * 0.5, ambient_diffuse, hemi);
				vec3 ambient_subsurface = back_irradiance * ambient_transmission_tint * transmission_amount * ambient_occlusion;
				ambient_subsurface *= mix(0.3, 1.0, transmission_view_dependency);
				subsurface_ambient += ambient_subsurface;

				vec2 envBRDF = texture(TEXTURE(lighting_data.brdf_lut_tex), vec2(NdotV, perceptual_roughness)).rg;

				vec3 ambient_specular = reflection * (F0 * envBRDF.x + envBRDF.y);
				ambient_specular *= GGXEnergyCompensation(F0, envBRDF);
				ambient_specular *= SpecularOcclusion(NdotV, ambient_occlusion, perceptual_roughness);
				ambient_specular *= 1.0 - subsurface_factor;

				vec3 ambient = ambient_diffuse + ambient_specular;
				ambient += (subsurface_ambient - ambient_diffuse) * subsurface_factor;
				return ambient;
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
					set_color(vec4(get_sky(), 1.0));
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


				vec3 albedo = get_albedo();
				float metallic = get_metallic();
				float roughness = get_roughness();
				float perceptual_roughness = sqrt(clamp(roughness, 0.0, 1.0));
				float subsurface = get_subsurface();
				float transmission_blocking = get_transmission_blocking();
				vec3 transmission_color = get_transmission_color();
				float transmission_view_dependency = get_transmission_view_dependency();
				vec3 emissive = subsurface > 0.0 ? vec3(0.0) : get_emissive();
				vec3 F0 = mix(vec3(0.04), albedo, metallic);
				float NdotV = max(dot(N, V), 0.001);
				vec3 direct = get_direct_light(F0, NdotV, albedo, roughness, perceptual_roughness, metallic, subsurface, transmission_blocking, transmission_color, transmission_view_dependency, world_pos, V, N);
				vec3 indirect = get_indirect_light(F0, NdotV, albedo, roughness, metallic, subsurface, transmission_blocking, transmission_color, transmission_view_dependency, world_pos, V, N);
				vec3 color = direct + indirect + emissive;
				vec3 sunDir = get_primary_sun_direction();
				float atmosphere_sun_visibility = 1.0;

				if (
					lighting_data.light_count > 0 &&
					lighting_data.shadows.shadow_map_indices[0] >= 0 &&
					lighting_data.shadows.directional_shadow_light_index >= 0
				) {
					atmosphere_sun_visibility = calculateShadow(world_pos, N, sunDir);
				}

				color = apply_atmospheric_aerial_perspective(
					color,
					world_pos,
					sunDir,
					lighting_data.camera_position.xyz,
					lighting_data.atmosphere_transmittance_texture_index,
					atmosphere_sun_visibility
				);

				set_color(vec4(color, alpha));
			}
		]],
	},
}
