local Vec3 = import("goluwa/structs/vec3.lua")
local system = import("goluwa/system.lua")
local assets = import("goluwa/assets.lua")
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
-- lying snow takes its albedo, roughness and normal from this material, loaded once snow first lies.
-- its textures tile every SNOW_TEXTURE_SIZE meters, projected from above
surface_weather.SNOW_MATERIAL = "materials/examples/snow.lua"
surface_weather.SNOW_TEXTURE_SIZE = 2.4
-- nil until snow first lies, false when there is no such material
surface_weather.snow_material = nil
-- the water film rain leaves on wet surfaces is this material's clearcoat, loaded once something is
-- first wet
surface_weather.RAIN_MATERIAL = "materials/examples/rain.lua"
-- nil until something is first wet, false when there is no such material
surface_weather.rain_material = nil
-- drops of every size that land on each m² of open ground per second, and those big enough to splash,
-- render3d/weather.lua sets them with the rain. together they stir the film on wet surfaces up into a
-- restless surface that runs down slopes, with the odd ring from a big drop on flat ground
surface_weather.rain_impact_rate = 0
surface_weather.splash_rate = 0
-- mm, the drops counted by each
surface_weather.AGITATION_MIN_DIAMETER = 0.5
surface_weather.SPLASH_MIN_DIAMETER = 3
surface_weather.block = {
	{"surface_wetness", "float"},
	{"surface_snow_depth", "float"},
	{"surface_snow_wetness", "float"},
	{"shelter_texture", "int"},
	{"shelter_texel_size", "float"},
	{"precipitation_spread", "float"},
	{"surface_frame", "int"},
	{"snow_albedo_tex", "int"},
	{"snow_roughness_tex", "int"},
	{"snow_normal_tex", "int"},
	{"snow_texture_scale", "float"},
	{"rain_clearcoat", "float"},
	{"rain_clearcoat_roughness", "float"},
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

	if block.surface_snow_depth > 0 and surface_weather.snow_material == nil then
		surface_weather.snow_material = assets.Load(surface_weather.SNOW_MATERIAL) or false
	end

	local snow = surface_weather.snow_material

	if snow then
		block.snow_albedo_tex = self:GetTextureIndex(snow:GetAlbedoTexture())
		block.snow_roughness_tex = self:GetTextureIndex(snow:GetRoughnessTexture())
		block.snow_normal_tex = self:GetTextureIndex(snow:GetNormalTexture())
	else
		block.snow_albedo_tex = -1
	end

	block.snow_texture_scale = 1 / surface_weather.SNOW_TEXTURE_SIZE

	if block.surface_wetness > 0 and surface_weather.rain_material == nil then
		surface_weather.rain_material = assets.Load(surface_weather.RAIN_MATERIAL) or false
	end

	local rain = surface_weather.rain_material

	if rain then
		block.rain_clearcoat = rain:GetClearcoat()
		block.rain_clearcoat_roughness = rain:GetClearcoatRoughness()
	else
		block.rain_clearcoat = 0
		block.rain_clearcoat_roughness = 1
	end

	surface_weather.precipitation_direction:CopyToFloatPointer(block.precipitation_direction)
	return block
end

do
	-- m across the stirred film's waves, their larger octave
	local AGITATION_SIZE = 0.05
	-- the waves' rms slope at 1000 drops per m² per second. the waves of many drops add up at random, so
	-- the slope goes as the square root of how many land
	local AGITATION_SLOPE = 0.06 * 1
	-- noise cells per second the film churns through in place
	local AGITATION_SPEED = 30
	-- m/s the film runs down a wall, down a slope times the sine of its angle
	local FLOW_SPEED = 0.5 * 10
	-- s before the flowing noise starts over, a whole number of splash lifetimes so the time's wrap
	-- doesn't cut it off. it moves by the direction downhill, which turns along a curved surface, so
	-- two copies half a period apart start over in turn and the pattern never tears (the flow map
	-- technique, Vlachos 2010)
	local FLOW_PERIOD = 1.6
	-- the noise is this much coarser upward, so the water running down walls draws out into streaks
	local AGITATION_STREAK = 0.25
	-- the big drops' rings: a grid of cells in a few offset layers, each cell a drop landing somewhere in it
	-- once a lifetime, or not. a ring spreads to a cell so the neighbouring cells hold every ring
	local SPLASH_CELL = 0.15
	local SPLASH_LAYERS = 2
	local SPLASH_LIFETIME = 0.8
	local SPLASH_RADIUS = SPLASH_CELL
	-- m across a ring's crests, and the steepest slope of its waves
	local SPLASH_WIDTH = 0.03
	local SPLASH_SLOPE = 0.3
	surface_weather.rain_surface_block = {
		{"rain_time", "float"},
		{"rain_agitation", "float"},
		{"splash_chance", "float"},
		{"splash_alpha", "float"},
	}

	function surface_weather.WriteRainSurfaceBlock(self, block)
		-- a whole number of splash lifetimes, so the wrap cuts no ring off. the churning jumps once
		block.rain_time = system.GetElapsedTime() % (SPLASH_LIFETIME * 4096)
		block.rain_agitation = AGITATION_SLOPE * math.sqrt(surface_weather.rain_impact_rate / 1000)
		-- the chance a cell's drop lands in a lifetime, to land the big drops on each m². heavy rain has
		-- more than the cells hold, the rest is in the churning
		local chance = math.min(surface_weather.splash_rate * SPLASH_LIFETIME * SPLASH_CELL * SPLASH_CELL / SPLASH_LAYERS, 1)
		block.splash_chance = chance
		-- far away the rings are too fine to see and only spread the film's reflection: the share of the
		-- surface a ring's waves are passing times their slope
		local coverage = math.min(
			chance * SPLASH_LAYERS * math.pi * SPLASH_RADIUS * 2 * SPLASH_WIDTH / (
					SPLASH_CELL * SPLASH_CELL
				),
			1
		)
		block.splash_alpha = SPLASH_SLOPE * math.sqrt(coverage)
	end

	-- apply_rain_surface(world_pos, footprint, rain, coat_N, coat_alpha) for a pass with rain_surface_block in
	-- block_name. rain is how much of the rain lands on the coat (gbuffer_clearcoat_rain), footprint the
	-- meters a pixel covers. it tilts the coat's normal where the waves are resolved and roughens the coat
	-- where they aren't
	function surface_weather.GetRainSurfaceGLSL(block_name)
		return (
			(
				[[
			const float AGITATION_SIZE = %f;
			const float AGITATION_SPEED = %f;
			const float FLOW_SPEED = %f;
			const float FLOW_PERIOD = %f;
			const float AGITATION_STREAK = %f;
			const float SPLASH_CELL = %f;
			const int SPLASH_LAYERS = %d;
			const float SPLASH_LIFETIME = %f;
			const float SPLASH_RADIUS = %f;
			const float SPLASH_WIDTH = %f;
			const float SPLASH_SLOPE = %f;
			// three crests across a ring
			const float SPLASH_CRESTS = 3.0 * 3.14159265;

			vec3 rain_hash(vec3 p) {
				p = fract(p * vec3(0.1031, 0.1030, 0.0973));
				p += dot(p, p.yxz + 33.33);
				return fract((p.xxy + p.yxx) * p.zyx);
			}

			// gradient noise, the value in x and its gradient in yzw (Quilez)
			vec4 rain_noise(vec3 x) {
				vec3 i = floor(x);
				vec3 f = fract(x);
				vec3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
				vec3 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
				vec3 ga = rain_hash(i) * 2.0 - 1.0;
				vec3 gb = rain_hash(i + vec3(1.0, 0.0, 0.0)) * 2.0 - 1.0;
				vec3 gc = rain_hash(i + vec3(0.0, 1.0, 0.0)) * 2.0 - 1.0;
				vec3 gd = rain_hash(i + vec3(1.0, 1.0, 0.0)) * 2.0 - 1.0;
				vec3 ge = rain_hash(i + vec3(0.0, 0.0, 1.0)) * 2.0 - 1.0;
				vec3 gf = rain_hash(i + vec3(1.0, 0.0, 1.0)) * 2.0 - 1.0;
				vec3 gg = rain_hash(i + vec3(0.0, 1.0, 1.0)) * 2.0 - 1.0;
				vec3 gh = rain_hash(i + vec3(1.0, 1.0, 1.0)) * 2.0 - 1.0;
				float va = dot(ga, f);
				float vb = dot(gb, f - vec3(1.0, 0.0, 0.0));
				float vc = dot(gc, f - vec3(0.0, 1.0, 0.0));
				float vd = dot(gd, f - vec3(1.0, 1.0, 0.0));
				float ve = dot(ge, f - vec3(0.0, 0.0, 1.0));
				float vf = dot(gf, f - vec3(1.0, 0.0, 1.0));
				float vg = dot(gg, f - vec3(0.0, 1.0, 1.0));
				float vh = dot(gh, f - vec3(1.0, 1.0, 1.0));
				return vec4(
					va + u.x * (vb - va) + u.y * (vc - va) + u.z * (ve - va) + u.x * u.y * (va - vb - vc + vd) + u.y * u.z * (va - vc - ve + vg) + u.z * u.x * (va - vb - ve + vf) + (-va + vb + vc - vd + ve - vf - vg + vh) * u.x * u.y * u.z,
					ga + u.x * (gb - ga) + u.y * (gc - ga) + u.z * (ge - ga) + u.x * u.y * (ga - gb - gc + gd) + u.y * u.z * (ga - gc - ge + gg) + u.z * u.x * (ga - gb - ge + gf) + (-ga + gb + gc - gd + ge - gf - gg + gh) * u.x * u.y * u.z +
					du * (vec3(vb, vc, ve) - va + u.yzx * vec3(va - vb - vc + vd, va - vc - ve + vg, va - vb - ve + vf) + u.zxy * vec3(va - vb - ve + vf, va - vb - vc + vd, va - vc - ve + vg) + u.yzx * u.zxy * (-va + vb + vc - vd + ve - vf - vg + vh))
				);
			}

			// the slope of the churning film at p, as the gradient of its height in world space
			// on the surface with normal N: it runs downhill, gravity along the surface, and churns in place by
			// moving through the noise along N
			vec3 get_rain_agitation_slope(vec3 p, vec3 N) {
				vec3 scale = vec3(1.0, AGITATION_STREAK, 1.0) / AGITATION_SIZE;
				vec3 downhill = N * N.y - vec3(0.0, 1.0, 0.0);
				vec3 gradient = vec3(0.0);
				float weight_sum = 0.0;

				for (int copy = 0; copy < 2; copy++) {
					float cycle = fract(BLOCK.rain_time / FLOW_PERIOD + float(copy) * 0.5);
					// faded out as it starts over
					float weight = 1.0 - abs(cycle * 2.0 - 1.0);
					float t = cycle * FLOW_PERIOD;
					vec3 moved = p - downhill * (FLOW_SPEED * t) - N * (AGITATION_SPEED * AGITATION_SIZE * t);
					// each copy a different stretch of the noise, and each period too
					vec3 q = moved * scale + vec3(float(copy) * 31.7 + floor(BLOCK.rain_time / FLOW_PERIOD + float(copy) * 0.5) * 7.3);
					gradient += (rain_noise(q).yzw + 0.6 * rain_noise(q * 2.3 + 17.1).yzw) * weight;
					weight_sum += weight * weight;
				}

				// two unrelated noises mixed lose contrast, as much as their weights' length falls below 1
				return gradient * inversesqrt(max(weight_sum, 1e-4)) * vec3(1.0, AGITATION_STREAK, 1.0) * BLOCK.rain_agitation;
			}

			// the slope of the big drops' rings at p in world xz
			vec2 get_rain_splash_slope(vec2 p) {
				vec2 slope = vec2(0.0);

				for (int layer = 0; layer < SPLASH_LAYERS; layer++) {
					vec2 q = p / SPLASH_CELL + vec2(float(layer) * 0.37, float(layer) * 0.71);
					vec2 cell = floor(q);

					for (int y = -1; y <= 1; y++) {
						for (int x = -1; x <= 1; x++) {
							vec2 c = cell + vec2(x, y);
							// each cell's drops come at its own phase, and land somewhere else each lifetime
							float t = BLOCK.rain_time / SPLASH_LIFETIME + rain_hash(vec3(c, float(layer))).x;
							vec3 drop = rain_hash(vec3(c + floor(t) * 17.13, float(layer) + 7.0));

							if (drop.z >= BLOCK.splash_chance) continue;

							float age = fract(t);
							vec2 delta = (q - c - drop.xy) * SPLASH_CELL;
							float d = length(delta);
							// across the ring's crests, -1 to 1
							float r = (d - age * SPLASH_RADIUS) / SPLASH_WIDTH;

							if (abs(r) >= 1.0 || d < 1e-5) continue;

							// three crests under a smooth window, their slope across the ring, fading as it spreads
							float w = 1.0 - r * r;
							float wave = SPLASH_CRESTS * cos(SPLASH_CRESTS * r) * w * w - 4.0 * r * w * sin(SPLASH_CRESTS * r);
							float fade = (1.0 - age) * (1.0 - age);
							slope += delta / d * (wave / SPLASH_CRESTS * fade * SPLASH_SLOPE);
						}
					}
				}

				return slope;
			}

			void apply_rain_surface(vec3 world_pos, float footprint, float rain, inout vec3 coat_N, inout float coat_alpha) {
				if (rain <= 0.0 || BLOCK.rain_agitation <= 0.0) return;

				vec3 N = coat_N;
				vec3 slope = vec3(0.0);
				float spread = 0.0;
				// resolved while the waves are a few pixels across
				float resolved = 1.0 - smoothstep(AGITATION_SIZE * 0.3, AGITATION_SIZE, footprint);

				if (resolved > 0.0) {
					slope += get_rain_agitation_slope(world_pos, N) * resolved;
				}

				spread += BLOCK.rain_agitation * (1.0 - resolved);

				// the rings only show where the water lies still, on flat ground
				float flatness = smoothstep(0.9, 0.98, N.y);

				if (BLOCK.splash_chance > 0.0 && flatness > 0.0) {
					float splash_resolved = 1.0 - smoothstep(SPLASH_WIDTH * 0.3, SPLASH_WIDTH, footprint);

					if (splash_resolved > 0.0) {
						vec2 s = get_rain_splash_slope(world_pos.xz) * flatness * splash_resolved;
						slope += vec3(s.x, 0.0, s.y);
					}

					spread = length(vec2(spread, BLOCK.splash_alpha * flatness * (1.0 - splash_resolved)));
				}

				// only the part of the slope along the surface tilts it
				slope -= N * dot(slope, N);
				coat_N = normalize(N - slope * rain);
				spread *= rain;
				coat_alpha = min(sqrt(coat_alpha * coat_alpha + spread * spread), 1.0);
			}
		]]
			):format(
				AGITATION_SIZE,
				AGITATION_SPEED,
				FLOW_SPEED,
				FLOW_PERIOD,
				AGITATION_STREAK,
				SPLASH_CELL,
				SPLASH_LAYERS,
				SPLASH_LIFETIME,
				SPLASH_RADIUS,
				SPLASH_WIDTH,
				SPLASH_SLOPE
			):gsub("BLOCK%.", block_name .. ".")
		)
	end
end

-- apply_surface_weather(albedo, alpha_roughness, metallic, normal, porosity, world_pos, geometric_normal, clearcoat,
-- clearcoat_alpha, rain). rain comes out as how much of the falling rain lands on the surface, for its ripples
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
		// the up component of a surface's normal where the rain starts to pool into a film (about 12
		// degrees), and below which it only runs off (about 45). a run off film covers this much, and is
		// this rough, perceptual
		const float RAIN_POOL_SLOPE = 0.98;
		const float RAIN_RUNOFF_SLOPE = 0.7;
		const float RAIN_RUNOFF_FILM = 0.35;
		const float RAIN_RUNOFF_ROUGHNESS = 0.3;
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

		float apply_surface_weather(inout vec3 albedo, inout float alpha_roughness, inout float metallic, inout vec3 normal, float porosity, vec3 world_pos, vec3 geometric_normal, inout float clearcoat, inout float clearcoat_alpha, out float rain) {
			float wetness = ]] .. block_name .. [[.surface_wetness;
			float snow_depth = ]] .. block_name .. [[.surface_snow_depth;
			rain = 0.0;

			if (wetness <= 0.0 && snow_depth <= 0.0) return 0.0;

			float exposure = get_precipitation_exposure(world_pos, geometric_normal);

			// water in the pores scatters less light back out, so a porous surface darkens (Lagarde 2013,
			// "Water drop 3b - Physically based wet surfaces"), and a film of it lies on top, a smooth
			// reflection over the rough surface under it
			if (wetness > 0.0) {
				float wet = wetness * exposure;
				albedo *= mix(1.0, mix(1.0, 0.2, porosity), wet);
				// the water pools into a film on flat ground. down a slope it runs off, thinner the steeper it
				// is, too thin to fill in the surface's roughness: a patchy, blurred sheen
				float pooling = smoothstep(RAIN_RUNOFF_SLOPE, RAIN_POOL_SLOPE, geometric_normal.y);
				float film = wet * ]] .. block_name .. [[.rain_clearcoat * mix(RAIN_RUNOFF_FILM, 1.0, pooling);

				if (film > clearcoat) {
					float film_roughness = mix(RAIN_RUNOFF_ROUGHNESS, ]] .. block_name .. [[.rain_clearcoat_roughness, pooling);
					clearcoat_alpha = mix(clearcoat_alpha, film_roughness * film_roughness, (film - clearcoat) / film);
					clearcoat = film;
				}

				rain = exposure;
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
			// and drops to ~60%, and is smoother
			float snow_wetness = ]] .. block_name .. [[.surface_snow_wetness;
			vec3 snow_albedo = vec3(0.9);
			float snow_roughness = 0.75;
			// the snow fills in the surface's detail
			vec3 snow_normal = geometric_normal;

			if (]] .. block_name .. [[.snow_albedo_tex >= 0) {
				// projected from above, u along +x and v along -z so the tangent frame is right handed
				vec2 uv = vec2(world_pos.x, -world_pos.z) * ]] .. block_name .. [[.snow_texture_scale;
				snow_albedo = texture(TEXTURE(]] .. block_name .. [[.snow_albedo_tex), uv).rgb;
				snow_roughness = texture(TEXTURE(]] .. block_name .. [[.snow_roughness_tex), uv).r;
				vec3 t = texture(TEXTURE(]] .. block_name .. [[.snow_normal_tex), uv).rgb * 2.0 - 1.0;
				// the grains' normal against straight up, tilted along with the surface under the snow
				snow_normal = normalize(vec3(t.x, t.z, -t.y) + geometric_normal - vec3(0.0, 1.0, 0.0));
			}

			snow_albedo *= mix(1.0, 0.6 / 0.9, snow_wetness);
			snow_roughness *= mix(1.0, 0.55 / 0.75, snow_wetness);
			albedo = mix(albedo, snow_albedo, cover);
			alpha_roughness = mix(alpha_roughness, snow_roughness * snow_roughness, cover);
			metallic *= 1.0 - cover;
			normal = normalize(mix(normal, snow_normal, cover));
			// the snow covers the water
			clearcoat *= 1.0 - cover;
			rain *= 1.0 - cover;
			return cover;
		}
	]]
end

return surface_weather
