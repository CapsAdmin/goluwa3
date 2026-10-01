local assets = import("goluwa/assets.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local envprobe = import("goluwa/render3d/envprobe.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local light_grid = import("goluwa/render3d/light_grid.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local glass_tint = import("goluwa/render3d/glass_tint.lua")
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
	glass_tint.cascade_block,
	post_source.pre_exposure_block,
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
	local gi_texture = ddgi.GetScreenTexture()
	block.gi_screen_tex = gi_texture and self:GetTextureIndex(gi_texture) or -1
	glass_tint.WriteCascadeBlock(self, block)
	post_source.WritePreExposureBlock(self, block)
	return block
end

function surface_lighting.GetDeclarationGLSL(grid_binding, occlusion_binding)
	return light_occlusion.GetDeclarationGLSL(occlusion_binding) .. light_grid.GetGLSL(grid_binding)
end

function surface_lighting.GetGLSL(block_name)
	return atmosphere.GetGLSLDefines(block_name, block_name .. ".primary_sun_illuminance") .. atmosphere.GetGLSLCode() .. post_source.GetPreExposureGLSL(block_name) .. [[

		#define saturate(x) clamp(x, 0.0, 1.0)
		]] .. ibl.GetBRDFGLSLCode() .. [[

		]] .. ibl.GetEnvironmentGLSLCode() .. [[

		]] .. ibl.GetProbeReflectionGLSLCode(block_name) .. [[

		]] .. scene_lights.GetLightGLSLCode() .. [[

		]] .. light_occlusion.GetSamplingGLSL(block_name) .. [[

		]] .. directional_shadows.GetSurfaceDirectionalShadowGLSL(block_name, "calculateShadow") .. [[

		]] .. scene_lights.GetPointShadowGLSL(block_name) .. [[

		]] .. directional_shadows.GetLocalDirectionalShadowGLSL(block_name) .. [[

		]] .. glass_tint.GetCascadeGLSL(block_name) .. [[

		vec3 get_primary_sun_direction() {
			vec3 sunDir = ]] .. block_name .. [[.primary_sun_direction.xyz;
			if (length(sunDir) < 0.0001) {
				sunDir = vec3(0.0, 1.0, 0.0);
			}
			return normalize(sunDir);
		}

		// how a thin surface spreads the light going through it, over the side facing away from the
		// light. lambert, blended by scattering towards a henyey greenstein lobe around the light's
		// direction with the same total over that side
		float transmission_phase(vec3 V, vec3 L, float scattering)
		{
			const float g = 0.6;
			float denominator = 1.0 + g * g + 2.0 * g * dot(V, L);
			float henyey_greenstein = (1.0 - g * g) / (4.0 * BRDF_PI * denominator * sqrt(denominator));
			return mix(1.0 / BRDF_PI, 2.0 * henyey_greenstein, scattering);
		}

		// returns the diffuse part, transmission included, and the specular part in
		// specular. a translucent surface scales them differently. transmission is
		// the part of the diffuse light that leaves through the side facing away
		// from the light instead of the lit one. a clearcoat lies over the surface along
		// coat_N, a film that fills in the surface's detail, and what it reflects doesn't
		// reach the surface
		vec3 get_direct_light(vec3 F0, float NdotV, vec3 albedo, float roughness_alpha, float perceptual_roughness, float metallic, float transmission, vec3 transmission_color, float transmission_scattering, vec3 world_pos, vec3 V, vec3 N, vec3 geometric_N, float clearcoat, float clearcoat_alpha, vec3 coat_N, out vec3 specular)
		{
			vec3 diffuse = vec3(0.0);
			specular = vec3(0.0);

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

				// the shadow maps' self shadowing fades out towards the terminator, by the
				// smooth normal since the geometric one of a tessellated surface would step
				float shadow_facing = get_shadow_facing(N, L);

				if (transmission > 0.0) {
					shadow_N = normalize((dot(geometric_N, L) < 0.0 ? -geometric_N : geometric_N) + L);
					shadow_facing = 1.0;
				}
				vec3 H = normalize(V + L);
				float NoL = saturate(dot(N, L));
				float NoH = saturate(dot(N, H));
				float LoH = saturate(dot(L, H));

				float lobe_alpha = roughness_alpha;
				float lobe_energy = 1.0;

				if (type == 0) {
					lobe_alpha = saturate(roughness_alpha + SUN_ANGULAR_RADIUS * 0.5);
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
					shadow_factor = calculateShadow(world_pos, shadow_N, L) * shadow_facing;
				}

				if (type == 0) {
					shadow_factor *= get_cloud_shadow(world_pos);
				} else if (
					i == ]] .. block_name .. [[.shadows.local_directional_shadow_light_index &&
					]] .. block_name .. [[.shadows.local_directional_shadow_map_index >= 0 &&
					type == 2
				) {
					shadow_factor = calculateLocalDirectionalShadow(world_pos, shadow_N, L) * shadow_facing;
				} else if (type == 1 || type == 3) {
					int point_shadow_slot = getPointShadowSlot(i);

					if (point_shadow_slot >= 0) {
						shadow_factor = calculatePointShadow(point_shadow_slot, world_pos, shadow_N, L);
					}

					shadow_factor *= light_oct_shadow_factor(]] .. block_name .. [[.bvh_oct_slot[i], light.position.xyz, light.params.x, world_pos);
				}
				vec3 radiance = light.color.rgb * light.color.a * attenuation * shadow_factor;

				if (type == 0) radiance *= get_glass_tint(world_pos);

				if (clearcoat > 0.0) {
					float coat_NoL = saturate(dot(coat_N, L));
					float coat_alpha = clearcoat_alpha;
					float coat_energy = 1.0;

					if (type == 0) {
						coat_alpha = saturate(clearcoat_alpha + SUN_ANGULAR_RADIUS * 0.5);
						coat_energy = clearcoat_alpha / coat_alpha;
						coat_energy *= coat_energy;
					}

					float Fc = F_SchlickScalar(CLEARCOAT_F0, LoH) * clearcoat;
					specular += D_GGXAlpha(coat_alpha, saturate(dot(coat_N, H))) * coat_energy * V_Kelemen(LoH) * Fc * radiance * coat_NoL;
					radiance *= 1.0 - Fc;
				}

				diffuse += Fd * radiance * NoL * (1.0 - transmission);
				specular += Fr * radiance * NoL;

				if (transmission > 0.0) {
					diffuse += transmission * transmission_color * albedo * (1.0 - metallic) * transmission_phase(V, L, transmission_scattering) * saturate(-dot(N, L)) * radiance;
				}
			}
			}

			return diffuse;
		}
	]]
end

return surface_lighting
