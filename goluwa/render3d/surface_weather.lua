local Vec3 = import("goluwa/structs/vec3.lua")
local system = import("goluwa/system.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
-- What the weather does to surfaces as they are written to the gbuffer, so lighting, reflections and
-- gi all see it. render3d/weather.lua sets the state and owns the shelter map, a depth map rendered
-- along the falling precipitation that tells sheltered surfaces apart.
local surface_weather = library()
-- 0 is dry, 1 is soaked
surface_weather.wetness = 0
-- meters of snow on open, flat ground
surface_weather.snow_depth = 0
-- toward where the rain and snow come from
surface_weather.precipitation_direction = Vec3(0, 1, 0)
-- the tangent of the angle the falling rain or snow strays from precipitation_direction, so the higher
-- an occluder is the softer the edge of its shelter
surface_weather.precipitation_spread = 0.2
-- a ShadowMap rendered along the precipitation, nil without render3d/weather.lua
surface_weather.shelter_map = nil
surface_weather.block = {
	{"surface_wetness", "float"},
	{"surface_snow_depth", "float"},
	{"surface_snow_wetness", "float"},
	{"shelter_texture", "int"},
	{"shelter_texel_size", "float"},
	{"precipitation_spread", "float"},
	{"surface_frame", "int"},
	{"precipitation_direction", "vec3"},
	{"shelter_matrix", "mat4"},
}

-- 0 for dry snow, 1 for the wet snow near and above freezing, which is darker, smoother and falls in
-- bigger, faster flakes
function surface_weather.GetSnowWetness()
	return math.smoothstep(-2, 0.5, atmosphere.GetTemperature())
end

function surface_weather.WriteBlock(self, block)
	-- no weather in a void
	block.surface_wetness = atmosphere.IsEnabled() and surface_weather.wetness or 0
	block.surface_snow_depth = atmosphere.IsEnabled() and surface_weather.snow_depth or 0
	block.surface_snow_wetness = surface_weather.GetSnowWetness()
	local map = surface_weather.shelter_map

	if map and map.enabled and map:IsCascadeSampleable(1) then
		block.shelter_texture = self:GetTextureIndex(map:GetDepthTexture(1))
		block.shelter_texel_size = map:GetCascadeTexelWorldSize(1)
		map:GetLightSpaceMatrix(1):CopyToFloatPointer(block.shelter_matrix)
	else
		block.shelter_texture = -1
	end

	block.precipitation_spread = surface_weather.precipitation_spread
	block.surface_frame = system.GetFrameNumber() % 64
	surface_weather.precipitation_direction:CopyToFloatPointer(block.precipitation_direction)
	return block
end

-- apply_surface_weather(albedo, alpha_roughness, metallic, normal, porosity, world_pos, geometric_normal)
-- for a shader with surface_weather.block in the uniform block block_name. it returns how much snow
-- covers the surface, for what else the snow hides. get_porosity(alpha_roughness, metallic) is the usual
-- guess for materials that don't know their own
function surface_weather.GetGLSL(block_name)
	return [[
		// an occluder has to be this far up the precipitation from a surface to shelter it, so a surface
		// doesn't shelter itself and pebbles don't leave dry spots
		const float SHELTER_MIN_HEIGHT = 0.3;
		// how far the dry edge right under an occluder is smeared, the splashes and the drops that bounce
		const float SHELTER_BLUR = 0.3;
		// m, the widest the edge of a shelter gets, and so how far around a point occluders are looked for
		const float SHELTER_MAX_BLUR = 8.0;
		// m of snow that hides flat open ground completely, less of it lies in patches
		const float SNOW_FULL_COVER_DEPTH = 0.05;
		const vec2 SHELTER_TAPS[4] = vec2[4](vec2(0.2, 0.55), vec2(-0.55, 0.2), vec2(-0.2, -0.55), vec2(0.55, -0.2));

		// how much of the falling rain or snow reaches this surface, 0 in a sheltered or downward facing spot.
		// it falls within a cone around its direction, so an occluder shelters what is right under it and the
		// edge of its shelter widens the higher above it is, as a soft shadow's does (Fernando 2005)
		float get_precipitation_exposure(vec3 world_pos, vec3 normal) {
			vec3 dir = ]] .. block_name .. [[.precipitation_direction;
			// rain runs down walls a little, but never wets a ceiling
			float facing = smoothstep(-0.3, 0.2, dot(normal, dir));

			if (facing <= 0.0 || ]] .. block_name .. [[.shelter_texture == -1) return facing;

			mat4 m = ]] .. block_name .. [[.shelter_matrix;
			float texel = ]] .. block_name .. [[.shelter_texel_size;
			vec4 light_space_pos = m * vec4(world_pos + normal * texel * 1.5, 1.0);
			vec3 coords = light_space_pos.xyz / light_space_pos.w;
			coords.xy = coords.xy * 0.5 + 0.5;

			if (any(lessThan(coords, vec3(0.0))) || any(greaterThan(coords, vec3(1.0)))) return facing;

			vec3 row_x = vec3(m[0].x, m[1].x, m[2].x);
			vec3 row_y = vec3(m[0].y, m[1].y, m[2].y);
			vec3 row_z = vec3(m[0].z, m[1].z, m[2].z);
			float depth_per_meter = length(row_z);
			vec2 meters_to_uv = 1.0 / (texel * vec2(textureSize(TEXTURE(]] .. block_name .. [[.shelter_texture), 0)));
			// the surface's plane in the map, as meters it rises up the precipitation per meter across it.
			// the precipitation mostly comes in slanted, so even flat ground is tilted in the map, and the taps
			// around a point are compared with the plane there rather than with the point
			vec3 g = vec3(dot(row_x, normal) / dot(row_x, row_x), dot(row_y, normal) / dot(row_y, row_y), dot(row_z, normal) / dot(row_z, row_z));
			vec2 slope = -2.0 * g.xy * meters_to_uv / (g.z * depth_per_meter);
			slope *= min(1.0, 4.0 / max(length(slope), 1e-6));
			// what is less than this far up the precipitation from the plane doesn't shelter it, and the texels
			// a gather reads are up to one away
			float receiver = coords.z - (SHELTER_MIN_HEIGHT + length(slope) * texel) * depth_per_meter;
			// interleaved gradient noise, a different rotation of the few taps each frame, the taa averages
			// them into a smooth edge
			vec2 pixel = gl_FragCoord.xy + 5.588238 * float(]] .. block_name .. [[.surface_frame);
			float angle = fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715)))) * 6.2831853;
			mat2 rotation = mat2(cos(angle), sin(angle), -sin(angle), cos(angle));
			// how far up the precipitation the occluder is, what is right above the surface if anything is, or
			// else the average of the occluders around it. the nearest texel, a filtered depth at a silhouette
			// would be an occluder at every height in between
			float blocker = texelFetch(TEXTURE(]] .. block_name .. [[.shelter_texture), ivec2(coords.xy * vec2(textureSize(TEXTURE(]] .. block_name .. [[.shelter_texture), 0))), 0).r;

			if (blocker >= receiver) {
				float blocker_sum = 0.0;
				float blocker_count = 0.0;

				for (int i = 0; i < 4; i++) {
					vec2 offset = rotation * SHELTER_TAPS[i] * SHELTER_MAX_BLUR;
					vec4 depths = textureGather(TEXTURE(]] .. block_name .. [[.shelter_texture), coords.xy + offset * meters_to_uv, 0);
					vec4 blocked = vec4(lessThan(depths, vec4(receiver + dot(slope, offset) * depth_per_meter)));
					blocker_sum += dot(depths - dot(slope, offset) * depth_per_meter, blocked);
					blocker_count += dot(blocked, vec4(1.0));
				}

				if (blocker_count == 0.0) return facing;

				blocker = blocker_sum / blocker_count;
			}

			float blur = clamp(SHELTER_BLUR + (coords.z - blocker) / depth_per_meter * ]] .. block_name .. [[.precipitation_spread, SHELTER_BLUR, SHELTER_MAX_BLUR);
			float open = 0.0;

			for (int i = 0; i < 4; i++) {
				vec2 offset = rotation * SHELTER_TAPS[i] * blur;
				vec4 depths = textureGather(TEXTURE(]] .. block_name .. [[.shelter_texture), coords.xy + offset * meters_to_uv, 0);
				open += dot(vec4(greaterThanEqual(depths, vec4(receiver + dot(slope, offset) * depth_per_meter))), vec4(0.0625));
			}

			return facing * open;
		}

		vec2 snow_gradient(vec2 cell) {
			uvec2 v = uvec2(ivec2(cell) + 32768) * uvec2(1664525u, 1013904223u);
			v.x += v.y * 1664525u;
			v.y += v.x * 1664525u;
			v ^= v >> 16u;
			v.x += v.y * 1664525u;
			float angle = float(v.x) * (6.2831853 / 4294967296.0);
			return vec2(cos(angle), sin(angle));
		}

		// gradient noise, about -0.7 to 0.7
		float snow_noise(vec2 p) {
			vec2 i = floor(p);
			vec2 f = fract(p);
			vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
			return mix(
				mix(dot(snow_gradient(i), f), dot(snow_gradient(i + vec2(1.0, 0.0)), f - vec2(1.0, 0.0)), u.x),
				mix(dot(snow_gradient(i + vec2(0.0, 1.0)), f - vec2(0.0, 1.0)), dot(snow_gradient(i + vec2(1.0, 1.0)), f - vec2(1.0, 1.0)), u.x),
				u.y
			);
		}

		// 0 to 1, rotated octaves so no grid shows
		float snow_patches(vec2 p) {
			const mat2 ROTATE = mat2(0.8, 0.6, -0.6, 0.8);
			float n = snow_noise(p * 0.5) * 0.55;
			p = ROTATE * p;
			n += snow_noise(p * 1.9) * 0.3;
			p = ROTATE * p;
			n += snow_noise(p * 7.3) * 0.15;
			return clamp(n + 0.5, 0.0, 1.0);
		}

		// rough dielectrics are porous and soak water up, smooth ones and metals don't (Lagarde 2013)
		float get_porosity(float alpha_roughness, float metallic) {
			return clamp((sqrt(alpha_roughness) - 0.5) / 0.4, 0.0, 1.0) * (1.0 - metallic);
		}

		float apply_surface_weather(inout vec3 albedo, inout float alpha_roughness, inout float metallic, inout vec3 normal, float porosity, vec3 world_pos, vec3 geometric_normal) {
			float wetness = ]] .. block_name .. [[.surface_wetness;
			float snow_depth = ]] .. block_name .. [[.surface_snow_depth;

			if (wetness <= 0.0 && snow_depth <= 0.0) return 0.0;

			float exposure = get_precipitation_exposure(world_pos, geometric_normal);

			// water in the pores scatters less light back out, so a porous surface darkens, and the water
			// on it smooths it (Lagarde 2013, "Water drop 3b - Physically based wet surfaces")
			if (wetness > 0.0) {
				float wet = wetness * exposure;
				float factor = mix(1.0, 0.2, porosity);
				albedo *= mix(1.0, factor, wet);
				float roughness = sqrt(alpha_roughness) * mix(1.0, factor, 0.5 * wet);
				alpha_roughness = clamp(roughness * roughness, 0.002, 1.0);
			}

			if (snow_depth <= 0.0) return 0.0;

			// thin snow lies in drifts and patches, the noise decides where the ground shows through first
			float patches = snow_patches(world_pos.xz);
			// snow slides off slopes steeper than about 60 degrees and lies evenly below about 30, however
			// deep it is, with a ragged edge between
			float hold = smoothstep(0.5, 0.87, geometric_normal.y + (patches - 0.5) * 0.3);
			// and it settles on the upward facing bumps of a surface first
			float amount = snow_depth / SNOW_FULL_COVER_DEPTH * exposure - (1.0 - clamp(normal.y, 0.0, 1.0)) * 0.3;
			float cover = smoothstep(patches * 0.7, patches * 0.7 + 0.3, amount) * hold;

			if (cover <= 0.0) return 0.0;

			// fresh dry snow reflects ~90% of visible light, wet snow holds water between coarser grains
			// and drops to ~60%
			float snow_wetness = ]] .. block_name .. [[.surface_snow_wetness;
			float snow_roughness = mix(0.75, 0.55, snow_wetness);
			albedo = mix(albedo, vec3(mix(0.9, 0.6, snow_wetness)), cover);
			alpha_roughness = mix(alpha_roughness, snow_roughness * snow_roughness, cover);
			metallic *= 1.0 - cover;
			// the snow fills in the surface's detail
			normal = normalize(mix(normal, geometric_normal, cover));
			return cover;
		}
	]]
end

return surface_weather
