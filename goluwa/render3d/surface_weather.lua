local Vec3 = import("goluwa/structs/vec3.lua")
-- What the weather does to surfaces as they are written to the gbuffer, so lighting, reflections and
-- gi all see it. render3d/weather.lua sets the state and owns the rain occlusion map, a depth map
-- rendered along the falling rain that tells sheltered surfaces apart.
local surface_weather = library()
-- 0 is dry, 1 is soaked
surface_weather.wetness = 0
-- toward where the rain comes from
surface_weather.rain_direction = Vec3(0, 1, 0)
-- a ShadowMap rendered along the rain, nil without render3d/weather.lua
surface_weather.rain_occlusion_map = nil
surface_weather.block = {
	{"surface_wetness", "float"},
	{"rain_occlusion_texture", "int"},
	{"rain_occlusion_texel_size", "float"},
	{"rain_direction", "vec3"},
	{"rain_occlusion_matrix", "mat4"},
}

function surface_weather.WriteBlock(self, block)
	block.surface_wetness = surface_weather.wetness
	local map = surface_weather.rain_occlusion_map

	if map and map.enabled and map:IsCascadeSampleable(1) then
		block.rain_occlusion_texture = self:GetTextureIndex(map:GetDepthTexture(1))
		block.rain_occlusion_texel_size = map:GetCascadeTexelWorldSize(1)
		map:GetLightSpaceMatrix(1):CopyToFloatPointer(block.rain_occlusion_matrix)
	else
		block.rain_occlusion_texture = -1
	end

	surface_weather.rain_direction:CopyToFloatPointer(block.rain_direction)
	return block
end

-- apply_surface_weather(albedo, alpha_roughness, porosity, world_pos, normal) for a shader with
-- surface_weather.block in the uniform block block_name. get_porosity(alpha_roughness, metallic)
-- is the usual guess for materials that don't know their own
function surface_weather.GetGLSL(block_name)
	return [[
		// an occluder has to be this far up the rain from a surface to shelter it, so a surface
		// doesn't shelter itself and pebbles don't leave dry spots
		const float RAIN_SHELTER_MIN_HEIGHT = 0.3;
		// how far the dry edge under a roof or canopy is smeared, the spread of the rain and its splashes
		const float RAIN_SHELTER_BLUR = 0.3;

		// how much of the rain reaches this surface, 0 in a sheltered or downward facing spot
		float get_rain_exposure(vec3 world_pos, vec3 normal) {
			vec3 rain = ]] .. block_name .. [[.rain_direction;
			// rain runs down walls a little, but never wets a ceiling
			float facing = smoothstep(-0.3, 0.2, dot(normal, rain));

			if (facing <= 0.0 || ]] .. block_name .. [[.rain_occlusion_texture == -1) return facing;

			mat4 m = ]] .. block_name .. [[.rain_occlusion_matrix;
			float texel = ]] .. block_name .. [[.rain_occlusion_texel_size;
			vec4 light_space_pos = m * vec4(world_pos + normal * texel * 1.5, 1.0);
			vec3 coords = light_space_pos.xyz / light_space_pos.w;
			coords.xy = coords.xy * 0.5 + 0.5;

			if (any(lessThan(coords, vec3(0.0))) || any(greaterThan(coords, vec3(1.0)))) return facing;

			float depth_per_meter = length(vec3(m[0].z, m[1].z, m[2].z));
			// a surface tilted away from the rain is higher up at the taps around it
			float n_dot_r = clamp(dot(normal, rain), 0.05, 1.0);
			float tan_slope = min(sqrt(1.0 - n_dot_r * n_dot_r) / n_dot_r, 4.0);
			float receiver = coords.z - (RAIN_SHELTER_MIN_HEIGHT + tan_slope * RAIN_SHELTER_BLUR) * depth_per_meter;
			// a fixed per point rotation turns the banding of the few taps into grain
			float angle = fract(52.9829189 * fract(dot(world_pos, vec3(0.06711056, 0.00583715, 0.0891234)) * 31.0)) * 6.2831853;
			mat2 rotation = mat2(cos(angle), sin(angle), -sin(angle), cos(angle));
			vec2 radius = vec2(RAIN_SHELTER_BLUR / (texel * vec2(textureSize(TEXTURE(]] .. block_name .. [[.rain_occlusion_texture), 0))));
			const vec2 TAPS[4] = vec2[4](vec2(0.2, 0.55), vec2(-0.55, 0.2), vec2(-0.2, -0.55), vec2(0.55, -0.2));
			float open = 0.0;

			for (int i = 0; i < 4; i++) {
				vec4 depths = textureGather(TEXTURE(]] .. block_name .. [[.rain_occlusion_texture), coords.xy + rotation * TAPS[i] * radius, 0);
				open += dot(vec4(greaterThanEqual(depths, vec4(receiver))), vec4(0.0625));
			}

			return facing * open;
		}

		// rough dielectrics are porous and soak water up, smooth ones and metals don't (Lagarde 2013)
		float get_porosity(float alpha_roughness, float metallic) {
			return clamp((sqrt(alpha_roughness) - 0.5) / 0.4, 0.0, 1.0) * (1.0 - metallic);
		}

		// water in the pores scatters less light back out, so a porous surface darkens, and the water
		// on it smooths it (Lagarde 2013, "Water drop 3b - Physically based wet surfaces")
		void apply_surface_weather(inout vec3 albedo, inout float alpha_roughness, float porosity, vec3 world_pos, vec3 normal) {
			float wetness = ]] .. block_name .. [[.surface_wetness;

			if (wetness <= 0.0) return;

			float wet = wetness * get_rain_exposure(world_pos, normal);
			float factor = mix(1.0, 0.2, porosity);
			albedo *= mix(1.0, factor, wet);
			float roughness = sqrt(alpha_roughness) * mix(1.0, factor, 0.5 * wet);
			alpha_roughness = clamp(roughness * roughness, 0.002, 1.0);
		}
	]]
end

return surface_weather
