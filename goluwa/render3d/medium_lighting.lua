local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
-- what the passes that light a medium (the froxel fog, the particles) share: the primary sun out of the lights block,
-- writing that block, and the local lights' scattering. They need scene_lights.GetLightGLSLCode, the light grid and
-- light_occlusion.GetSamplingGLSL, atmosphere.GetGLSLDefines and directional_shadows.GetMediumDirectionalShadowGLSL
-- in front of them
local medium_lighting = {}

function medium_lighting.GetSunHelpersGLSL(data_block)
	return [[
		int get_current_primary_sun_index() {
			for (int i = 0; i < ]] .. data_block .. [[.light_count; i++) {
				if (get_light_type(]] .. data_block .. [[.lights[i]) == 0) return i;
			}

			return -1;
		}

		vec3 get_current_primary_sun_direction() {
			int sun_index = get_current_primary_sun_index();

			if (sun_index < 0) return vec3(0.0, 1.0, 0.0);

			return normalize(-]] .. data_block .. [[.lights[sun_index].direction.xyz);
		}

		float get_current_primary_sun_illuminance() {
			int sun_index = get_current_primary_sun_index();
			return sun_index < 0 ? ]] .. string.format("%.17g", atmosphere.GetSunIlluminance()) .. [[ : ]] .. data_block .. [[.lights[sun_index].color.a;
		}
	]]
end

function medium_lighting.WriteLightsBlock(self, block)
	local lights = render3d.GetLights()
	scene_lights.WriteLightsBlock(block.lights, lights)
	block.light_count = math.min(#lights, scene_lights.MAX_LIGHTS)
	scene_lights.WriteShadowBlock(self, block.shadows, lights)
	atmosphere.WriteBlock(
		self,
		block,
		render3d.GetCamera():GetPosition(),
		directional_shadows.GetPrimarySunDirection(render3d.GetLights())
	)
	return lights
end

-- get_local_light_scattering(ray_dir, world_pos, g): the light of the local lights (not the sun) around world_pos
-- that a medium there scatters along ray_dir (the direction from the viewer), with a Henyey-Greenstein phase of
-- asymmetry g. At most limit lights are counted
function medium_lighting.GetLocalLightsGLSL(data_block, limit)
	return [[
		float calculateLocalDirectionalMediumShadow(vec3 world_pos, vec3 light_dir) {
			int shadow_map_idx = ]] .. data_block .. [[.shadows.local_directional_shadow_map_index;

			if (shadow_map_idx < 0) return 1.0;

			vec3 proj_coords;

			if (!projectMediumShadowMap(]] .. data_block .. [[.shadows.local_directional_light_space_matrix, world_pos, proj_coords)) return 1.0;

			return sampleMediumShadowProjection(shadow_map_idx, proj_coords, 1.35);
		}

		vec3 get_local_light_scattering(vec3 ray_dir, vec3 world_pos, float g) {
			vec3 result = vec3(0.0);
			int processed = 0;

			int light_cell = light_grid_cell(world_pos);

			for (int w = 0; w < light_grid_words(]] .. data_block .. [[.light_count) && processed < ]] .. limit .. [[; w++) {
			uint light_bits = light_grid_word(light_cell, w, ]] .. data_block .. [[.light_count);

			while (light_bits != 0u && processed < ]] .. limit .. [[) {
				int i = w * 32 + findLSB(light_bits);
				light_bits &= light_bits - 1u;
				lights_t light = ]] .. data_block .. [[.lights[i];
				int type = get_light_type(light);

				if (type == 0) continue;

				vec3 L;
				float attenuation;

				if (!get_light_vector_and_attenuation(light, world_pos, L, attenuation) || attenuation <= 0.0001) continue;

				float occlusion = light_oct_shadow_factor(]] .. data_block .. [[.bvh_oct_slot[i], light.position.xyz, light.params.x, world_pos);

				if (occlusion <= 0.0) continue;

				processed++;
				// a soft core in the air for lights with a glow radius, so they glow instead of showing a hot spot
				float core_falloff = get_light_falloff(light, length(light.position.xyz - world_pos));
				attenuation *= core_falloff / max(core_falloff + light.falloff.w * light.falloff.w, 0.0001);
				float shadow = 1.0;

				if (type == 1) {
					int point_shadow_slot = getPointShadowSlot(i);

					if (point_shadow_slot >= 0) shadow = calculatePointShadow(point_shadow_slot, world_pos, L, L);
				} else if (type == 2 && i == ]] .. data_block .. [[.shadows.local_directional_shadow_light_index) {
					shadow = calculateLocalDirectionalMediumShadow(world_pos, L);
				}

				result += light.color.rgb * light.color.a * attenuation * shadow * occlusion * phase_henyey_greenstein(dot(ray_dir, L), g);
			}
			}

			return result;
		}
	]]
end

return medium_lighting
