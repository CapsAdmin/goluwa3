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
local glass_light = import("goluwa/render3d/glass_light.lua")
local surface_features = import("goluwa/render3d/surface_features.lua")
local surface_lighting = {}
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
	{"gi_screen_geometry_tex", "int"},
	{"glass_light", "int"},
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
	local environment = render3d.GetEnvironment()

	if environment then
		atmosphere.WriteDisabledBlock(self, block, environment:GetSourceTexture(), environment:GetIntensity())
	else
		atmosphere.WriteBlock(self, block, render3d.GetCamera():GetPosition(), sun_direction)
	end

	block.env_irradiance_tex = self:GetTextureIndex(render3d.GetEnvironmentIrradianceTexture())
	envprobe.WriteProbeBlock(self, block)
	local gi_texture = ddgi.GetScreenTexture()
	block.gi_screen_tex = gi_texture and self:GetTextureIndex(gi_texture) or -1
	local gi_geometry_texture = ddgi.GetScreenGeometryTexture()
	block.gi_screen_geometry_tex = gi_geometry_texture and self:GetTextureIndex(gi_geometry_texture) or -1
	block.glass_light = (glass_light.IsEnabled() and ddgi.HasGlass()) and 1 or 0
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

		#ifndef GLASS_LIGHT
		vec3 get_glass_light(vec3 origin, vec3 dir, float distance, float search_radius) {
			return vec3(1.0);
		}
		#endif

		// the exposed radiance (1 is white) below which a light isn't shaded at all
		#define LIGHT_MIN_SCREEN_RADIANCE 0.0002

		vec3 get_primary_sun_direction() {
			vec3 sunDir = ]] .. block_name .. [[.primary_sun_direction.xyz;
			if (length(sunDir) < 0.0001) {
				sunDir = vec3(0.0, 1.0, 0.0);
			}
			return normalize(sunDir);
		}

		]] .. surface_features.GetCommonGLSL() .. [[

		]] .. surface_features.GetSurfaceGLSL() .. [[

		]] .. surface_features.GetDefaultFunctionGLSL() .. surface_features.GetFinishFunctionGLSL() .. [[

		// returns the diffuse part and the specular part in specular, a translucent surface
		// scales them differently. features layer over and add to the base lobe, see
		// surface_features.lua
		vec3 get_direct_light(in Surface s, out vec3 specular)
		{
			vec3 diffuse = vec3(0.0);
			specular = vec3(0.0);

			int light_cell = light_grid_cell(s.world_pos);

			for (int w = 0; w < light_grid_words(]] .. block_name .. [[.light_count); w++) {
			uint light_bits = light_grid_word(light_cell, w, ]] .. block_name .. [[.light_count);

			while (light_bits != 0u) {
				int i = w * 32 + findLSB(light_bits);
				light_bits &= light_bits - 1u;
				lights_t light = ]] .. block_name .. [[.lights[i];
				int type = get_light_type(light);
				vec3 L;
				float attenuation = 1.0;
				if (!get_light_vector_and_attenuation(light, s.world_pos, L, attenuation)) {
					continue;
				}

				vec3 unshadowed_radiance = light.color.rgb * light.color.a * attenuation;

				// a light that can't show on screen isn't shaded. a smooth surface shows a light brighter
				// than it is as a highlight, so what the lobe's peak makes of it is counted
				float lobe_alpha_min = s.roughness_alpha;
				]] .. surface_features.GetDirectPeakGLSL() .. [[
				float brightest = max(max(unshadowed_radiance.r, unshadowed_radiance.g), unshadowed_radiance.b) * max(1.0, 0.08 / max(lobe_alpha_min * lobe_alpha_min, 1e-4));

				if (brightest * get_exposure() < LIGHT_MIN_SCREEN_RADIANCE) continue;
				// the shadow maps' self shadowing fades out towards the terminator, by the
				// smooth normal since the geometric one of a tessellated surface would step
				vec3 shadow_N = s.geometric_N;
				float shadow_facing = get_shadow_facing(s.N, L);
				]] .. surface_features.GetDirectShadowGLSL() .. [[
				vec3 H = normalize(s.V + L);
				float NoL = saturate(dot(s.N, L));
				float NoH = saturate(dot(s.N, H));
				float LoH = saturate(dot(L, H));

				float shadow_factor = 1.0;
				if (
					i == ]] .. block_name .. [[.shadows.directional_shadow_light_index &&
					]] .. block_name .. [[.shadows.shadow_map_indices[0] >= 0 &&
					type == 0
				) {
					shadow_factor = calculateShadow(s.world_pos, shadow_N, L) * shadow_facing;
				}

				// a shadow map that decides the light's visibility alone takes the contact shadow's place
				bool screen_marchable = true;

				if (type == 0) {
					if (shadow_factor > 0.0) shadow_factor *= get_cloud_shadow(s.world_pos);
				} else if (
					i == ]] .. block_name .. [[.shadows.local_directional_shadow_light_index &&
					]] .. block_name .. [[.shadows.local_directional_shadow_map_index >= 0 &&
					type == 2
				) {
					shadow_factor = calculateLocalDirectionalShadow(s.world_pos, shadow_N, L) * shadow_facing;
					screen_marchable = false;
				} else if (type == 1 || type == 3) {
					int point_shadow_slot = getPointShadowSlot(i);

					if (point_shadow_slot >= 0) {
						shadow_factor = calculatePointShadow(point_shadow_slot, s.world_pos, shadow_N, L);
						screen_marchable = false;
					}

					shadow_factor *= light_oct_shadow_factor(]] .. block_name .. [[.bvh_oct_slot[i], light.position.xyz, light.params.x, s.world_pos);
				}

				#ifdef SHADOW_SCREEN_SPACE
				// the exposed radiance (1 is white) below which a light's contact shadow isn't marched
				#define SCREEN_SHADOW_MIN_SCREEN_RADIANCE 0.002
				// the shadow maps' texels are too coarse for detail like grass, and their
				// offsets against self shadowing carry the lookup past close occluders,
				// so what the gbuffer shows is marched on top, for every kind of light.
				// it comes last because a light the other shadows leave too dim on screen for its
				// contact shadow to show isn't marched, and most lights reach through walls
				if (screen_marchable && ]] .. block_name .. [[.screen_shadows != 0 && NoL > 0.0 && max(max(unshadowed_radiance.r, unshadowed_radiance.g), unshadowed_radiance.b) * shadow_factor * NoL * get_exposure() >= SCREEN_SHADOW_MIN_SCREEN_RADIANCE) {
					float reach = ]] .. block_name .. [[.screen_shadow_length;
					bool reach_is_light = false;

					if (type == 0) {
						reach = clamp(shadow_texel_world_size * 8.0, 0.5, reach);
					} else if (type != 2) {
						float light_distance = length(light.position.xyz - s.world_pos);
						reach_is_light = light_distance <= reach;
						reach = min(light_distance, reach);
					}

					float screen_visibility = screen_space_shadow_visibility(s.world_pos, shadow_N, L, reach, reach_is_light);
					screen_shadow_term = min(screen_shadow_term, screen_visibility);
					shadow_factor *= screen_visibility;
				}
				#endif

				vec3 radiance = unshadowed_radiance * shadow_factor;

				// nothing to add from a light that is shadowed away entirely, and most lights reach through walls
				if (radiance.r + radiance.g + radiance.b <= 0.0) continue;

				#ifdef GLASS_LIGHT
				if (]] .. block_name .. [[.glass_light != 0) {
					float glass_distance = type == 0 ? GLASS_SUN_DISTANCE : (type == 2 ? 50.0 : max(length(light.position.xyz - s.world_pos) - 0.05, 0.0));
					// where a shadow map is only partly lit (a penumbra) glass beside the frame casting it is looked for
					float glass_search = type == 0 && shadow_factor < 0.999 ? clamp(shadow_texel_world_size * 3.0, 0.05, 0.5) : 0.0;
					radiance *= get_glass_light(s.world_pos + shadow_N * 0.02, L, glass_distance, glass_search);
				}
				#endif

				float lobe_alpha = s.roughness_alpha;
				float lobe_energy = 1.0;

				if (type == 0) {
					lobe_alpha = saturate(s.roughness_alpha + SUN_ANGULAR_RADIUS * 0.5);
					lobe_energy = s.roughness_alpha / lobe_alpha;
					lobe_energy *= lobe_energy;
				}

				float glow_widening = 0.0;

				if (type != 0 && light.falloff.w > 0.0) {
					// a light with a glow radius is a sphere, its highlight is the lobe widened by the angle it covers
					glow_widening = light.falloff.w * 0.5 / max(length(light.position.xyz - s.world_pos), 0.0001);
					lobe_alpha = saturate(s.roughness_alpha + glow_widening);
					lobe_energy = s.roughness_alpha / lobe_alpha;
					lobe_energy *= lobe_energy;
				}

				float D = D_GGXAlpha(lobe_alpha, NoH) * lobe_energy;
				float V_func = V_SmithGGXCorrelated(s.roughness_alpha, s.NdotV, NoL);
				vec3 F = F_Schlick(s.F0, LoH);

				vec3 Fr = (D * V_func) * F;
				vec3 kD = (1.0 - F) * (1.0 - s.metallic);
				vec3 Fd = kD * s.albedo * Fd_Burley(NoL, s.NdotV, LoH, s.perceptual_roughness);

				float diffuse_weight = 1.0;
				]] .. surface_features.GetDirectLayerGLSL() .. [[

				diffuse += Fd * radiance * NoL * diffuse_weight;
				specular += Fr * radiance * NoL;
				]] .. surface_features.GetDirectGLSL() .. [[
			}
			}

			return diffuse;
		}
	]]
end

return surface_lighting
