local assets = import("goluwa/assets.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local envprobe = import("goluwa/render3d/envprobe.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local light_grid = import("goluwa/render3d/light_grid.lua")
local surface_lighting = library()
-- What shading a surface at a world position takes, shared by the deferred
-- lighting pass and the forward passes that draw what the gbuffer can't hold.
-- A pass puts surface_lighting.block in a uniform block, writes it with
-- WriteBlock, binds the light grid and the occlusion map at the bindings it
-- gave GetDeclarationGLSL, and shades with get_direct_light from GetGLSL.
surface_lighting.block = {
	render3d.camera_block,
	{"lights", scene_lights.BuildLightsBlockLayout(), scene_lights.MAX_LIGHTS},
	{"light_count", "int"},
	{"shadows", scene_lights.BuildShadowsBlockLayout()},
	{"env_tex", "int"},
	{"brdf_lut_tex", "int"},
	render3d.common_block,
	light_occlusion.GetBlockLayout(),
	{"primary_sun_illuminance", "float"},
	{"primary_sun_color", "vec4"},
	{"primary_sun_direction", "vec4"},
	atmosphere.GetBlockLayout(),
	{"env_irradiance_tex", "int"},
	envprobe.GetProbeBlockLayout(),
	{"gi_screen_tex", "int"},
}

function surface_lighting.WriteBlock(self, block)
	render3d.WriteCameraBlock(self, block)
	local lights = render3d.GetLights()
	block.light_count = math.min(#lights, scene_lights.MAX_LIGHTS)
	scene_lights.WriteLightsBlock(block.lights, lights)
	scene_lights.WriteShadowBlock(self, block.shadows, lights)
	block.env_tex = self:GetTextureIndex(render3d.GetEnvironmentTexture())
	block.brdf_lut_tex = self:GetTextureIndex(assets.GetTexture("textures/render/brdf_lut.lua"))
	render3d.WriteCommonBlock(self, block)
	light_occlusion.WriteOcclusionBlock(block, lights)
	local primary_sun = directional_shadows.GetPrimarySun(lights)
	local sun_direction = directional_shadows.GetPrimarySunDirection(lights)
	sun_direction:CopyToFloatPointer(block.primary_sun_direction)
	block.primary_sun_illuminance = directional_shadows.GetPrimarySunIlluminance(lights)
	block.primary_sun_color[0] = primary_sun and primary_sun.Color.x or 1
	block.primary_sun_color[1] = primary_sun and primary_sun.Color.y or 1
	block.primary_sun_color[2] = primary_sun and primary_sun.Color.z or 1
	block.primary_sun_color[3] = 0
	atmosphere.WriteBlock(self, block, render3d.GetCamera():GetPosition(), sun_direction)
	block.env_irradiance_tex = self:GetTextureIndex(render3d.GetEnvironmentIrradianceTexture())
	envprobe.WriteProbeBlock(self, block)
	local gi_provider = render3d.GetGIProvider()
	local gi_texture = gi_provider and gi_provider.GetScreenTexture() or nil
	block.gi_screen_tex = gi_texture and self:GetTextureIndex(gi_texture) or -1
	return block
end

function surface_lighting.GetDeclarationGLSL(grid_binding, occlusion_binding)
	return light_occlusion.GetDeclarationGLSL(occlusion_binding) .. light_grid.GetGLSL(grid_binding)
end

function surface_lighting.GetGLSL(block_name)
	return atmosphere.GetGLSLDefines(block_name, block_name .. ".primary_sun_illuminance") .. atmosphere.GetGLSLCode() .. [[

		const float SUN_ANGULAR_RADIUS_TAN = 0.0047;

		#define saturate(x) clamp(x, 0.0, 1.0)
		]] .. ibl.GetBRDFGLSLCode() .. [[

		]] .. ibl.GetEnvironmentGLSLCode() .. [[

		]] .. ibl.GetProbeReflectionGLSLCode(block_name) .. [[

		]] .. scene_lights.GetLightGLSLCode() .. [[

		]] .. light_occlusion.GetSamplingGLSL(block_name) .. [[

		]] .. directional_shadows.GetSurfaceDirectionalShadowGLSL(block_name, "calculateShadow") .. [[

		]] .. scene_lights.GetPointShadowGLSL(block_name) .. [[

		]] .. directional_shadows.GetLocalDirectionalShadowGLSL(block_name) .. [[

		vec3 get_primary_sun_direction() {
			vec3 sunDir = ]] .. block_name .. [[.primary_sun_direction.xyz;
			if (length(sunDir) < 0.0001) {
				sunDir = vec3(0.0, 1.0, 0.0);
			}
			return normalize(sunDir);
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

		// returns the diffuse part, subsurface included, and the specular part in
		// specular. a translucent surface scales them differently
		vec3 get_direct_light(vec3 F0, float NdotV, vec3 albedo, float roughness_alpha, float perceptual_roughness, float metallic, float subsurface, float transmission_blocking, vec3 transmission_color, float transmission_view_dependency, vec3 world_pos, vec3 V, vec3 N, vec3 geometric_N, out vec3 specular)
		{
			vec3 diffuse = vec3(0.0);
			specular = vec3(0.0);
			float subsurface_factor = subsurface;

			int light_cell = light_grid_cell(world_pos);

			for (int w = 0; w < light_grid_words(]] .. block_name .. [[.light_count); w++) {
			uint light_bits = light_grid_word(light_cell, w, ]] .. block_name .. [[.light_count);

			while (light_bits != 0u) {
				int i = w * 32 + findLSB(light_bits);
				light_bits &= light_bits - 1u;
				lights_t light = ]] .. block_name .. [[.lights[i];
				int type = get_light_type(light);
				vec3 L;
				float attenuation = 1.0;
				if (!get_light_vector_and_attenuation(light, world_pos, L, attenuation)) {
					continue;
				}
				// light reaches a thin translucent surface from either side, so
				// its shadow is looked up on the side facing the light, and bent
				// towards the light so edge on doesn't read as facing away
				vec3 shadow_N = geometric_N;

				if (subsurface > 0.0) {
					shadow_N = normalize((dot(geometric_N, L) < 0.0 ? -geometric_N : geometric_N) + L);
				}
				vec3 H = normalize(V + L);
				float NoL = saturate(dot(N, L));
				float NoH = saturate(dot(N, H));
				float LoH = saturate(dot(L, H));

				float lobe_alpha = roughness_alpha;
				float lobe_energy = 1.0;

				if (type == 0) {
					lobe_alpha = saturate(roughness_alpha + SUN_ANGULAR_RADIUS_TAN * 0.5);
					lobe_energy = roughness_alpha / lobe_alpha;
					lobe_energy *= lobe_energy;
				}

				float D = D_GGXAlpha(lobe_alpha, NoH) * lobe_energy;
				float V_func = V_SmithGGXCorrelated(roughness_alpha, NdotV, NoL);
				vec3 F = F_Schlick(F0, LoH);

				vec3 Fr = (D * V_func) * F;
				vec3 kD = (1.0 - F) * (1.0 - metallic);
				vec3 Fd = kD * albedo * Fd_Burley(NoL, NdotV, LoH, perceptual_roughness);

				float shadow_factor = 1.0;
				if (
					i == ]] .. block_name .. [[.shadows.directional_shadow_light_index &&
					]] .. block_name .. [[.shadows.shadow_map_indices[0] >= 0 &&
					type == 0
				) {
					shadow_factor = calculateShadow(world_pos, shadow_N, L);
				} else if (
					i == ]] .. block_name .. [[.shadows.local_directional_shadow_light_index &&
					]] .. block_name .. [[.shadows.local_directional_shadow_map_index >= 0 &&
					type == 2
				) {
					shadow_factor = calculateLocalDirectionalShadow(world_pos, shadow_N, L);
				} else if (type == 1 || type == 3) {
					int point_shadow_slot = getPointShadowSlot(i);

					if (point_shadow_slot >= 0) {
						shadow_factor = calculatePointShadow(point_shadow_slot, world_pos, shadow_N, L);
					}

					shadow_factor *= light_oct_shadow_factor(]] .. block_name .. [[.bvh_oct_slot[i], light.position.xyz, light.params.x, world_pos);
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

				float lit = NoL * shadow_factor;
				vec3 subsurface_light = subsurface_front + subsurface_spec + transmission;
				diffuse += mix(Fd * radiance * lit, subsurface_light, subsurface_factor);
				specular += Fr * radiance * lit * (1.0 - subsurface_factor);
			}
			}

			return diffuse;
		}
	]]
end

return surface_lighting
