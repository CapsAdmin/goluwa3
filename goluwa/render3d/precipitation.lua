local pvars = import("goluwa/cli/pvars.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local surface_weather = import("goluwa/render3d/surface_weather.lua")
local particles = import("goluwa/render3d/particles.lua")
local precipitation = {}
precipitation.name = "precipitation"
precipitation.rain_rate = 0
precipitation.snow_rate = 0
local MARSHALL_PALMER_N0 = 8000
local RAIN_MIN_DIAMETER = 1
local RAIN_MAX_DIAMETER = 6
local SNOW_MIN_MELTED_DIAMETER = 0.5
local SNOW_MAX_MELTED_DIAMETER = 3
local SNOW_DENSITY_SCALE = 0.17
local BOX_SIZE = 20
local MAX_RAIN_DROPS = 131072
local MAX_SNOWFLAKES = 131072
local EXPOSURE_TIME = 1 / 60
-- geometric optics of a water sphere without its diffraction peak
local RAIN_SCATTER_G = 0.81
-- an ice aggregate without its diffraction peak scatters less forward than a drop
local SNOW_SCATTER_G = 0.6

function precipitation.SetRain(mm_per_hour)
	precipitation.rain_rate = mm_per_hour
end

function precipitation.GetRain()
	return precipitation.rain_rate
end

function precipitation.SetSnow(mm_per_hour)
	precipitation.snow_rate = mm_per_hour
end

function precipitation.GetSnow()
	return precipitation.snow_rate
end

local function get_rain_lambda()
	return 4.1 * precipitation.rain_rate ^ -0.21
end

local function get_snow_distribution()
	local rate = precipitation.snow_rate
	return 3800 * rate ^ -0.87, 2.55 * rate ^ -0.48
end

local function get_drawn(physical, max)
	if physical <= 0 then return 0, 0 end

	local drawn = math.min(math.ceil(physical), max)
	return drawn, physical / drawn
end

function precipitation.GetRainDropCount()
	if precipitation.rain_rate <= 0 then return 0, 0 end

	local lambda = get_rain_lambda()
	return get_drawn(
		MARSHALL_PALMER_N0 / lambda * math.exp(-lambda * RAIN_MIN_DIAMETER) * BOX_SIZE ^ 3,
		MAX_RAIN_DROPS
	)
end

function precipitation.GetRainImpactRate(min_diameter)
	if precipitation.rain_rate <= 0 then return 0 end

	local lambda = get_rain_lambda()
	local k = lambda + 0.6
	return MARSHALL_PALMER_N0 * (
			9.65 / lambda * (
				math.exp(-lambda * min_diameter) - math.exp(-lambda * RAIN_MAX_DIAMETER)
			) - 10.3 / k * (
				math.exp(-k * min_diameter) - math.exp(-k * RAIN_MAX_DIAMETER)
			)
		)
end

function precipitation.GetSnowflakeCount()
	if precipitation.snow_rate <= 0 then return 0, 0 end

	local n0, lambda = get_snow_distribution()
	return get_drawn(
		n0 / lambda * math.exp(-lambda * SNOW_MIN_MELTED_DIAMETER) * BOX_SIZE ^ 3,
		MAX_SNOWFLAKES
	)
end

function precipitation.GetExtinction()
	local extinction = 0

	if precipitation.rain_rate > 0 then
		extinction = extinction + 1.076 * precipitation.rain_rate ^ 0.67 / (10 / math.log(10))
	end

	if precipitation.snow_rate > 0 then
		local n0, lambda = get_snow_distribution()
		local size_scale = 1 + surface_weather.GetSnowWetness()
		extinction = extinction + 3 * math.pi * n0 * size_scale ^ 2 / (
				SNOW_DENSITY_SCALE * lambda ^ 4
			) * 1e-3
	end

	return extinction
end

pvars.StartGroup("Environment", "Precipitation", {store = false, prefix = "feature_"})
local enabled = pvars.Setup2{
	key = "r_feature_precipitation",
	default = true,
	friendly = "precipitation",
	help = "falling rain and snow around the camera",
}
pvars.EndGroup()

function precipitation.IsActive()
	return enabled:Get() and
		atmosphere.IsEnabled() and
		(
			precipitation.rain_rate > 0 or
			precipitation.snow_rate > 0
		)
end

-- the particles live in a box around the camera and wrap around its sides, so the density is the same wherever the
-- camera goes. They fall with the wind, hit what the shelter map sees (a roof, a canopy, the ground) and are hidden
-- under it
local function get_common_glsl()
	return [[
		#ifndef PRECIPITATION_COMMON
		#define PRECIPITATION_COMMON
		const float PRECIPITATION_BOX = ]] .. string.format("%.1f", BOX_SIZE) .. [[;

		vec3 wrap_into_camera_box(vec3 position) {
			vec3 camera = particle_data.camera_position;
			return camera + (fract((position - camera) / PRECIPITATION_BOX + 0.5) - 0.5) * PRECIPITATION_BOX;
		}

		vec3 get_camera_box_position(vec3 unorm) {
			return particle_data.camera_position + (unorm - 0.5) * PRECIPITATION_BOX;
		}
		#endif
	]]
end

precipitation.rain = particles.Register{
	name = "rain",
	max_count = MAX_RAIN_DROPS,
	scatter_g = RAIN_SCATTER_G,
	streak_time = EXPOSURE_TIME,
	fade_time = 0.3,
	fade_near = 1,
	fade_far = BOX_SIZE * 0.5,
	depth_near = 0.3,
	depth_far = BOX_SIZE,
	IsActive = function()
		return enabled:Get() and atmosphere.IsEnabled() and precipitation.rain_rate > 0
	end,
	GetCount = precipitation.GetRainDropCount,
	block = {
		{"lambda", "float"},
		{"wind", "vec3"},
	},
	WriteBlock = function(self, block)
		block.lambda = get_rain_lambda()
		atmosphere.GetWind():CopyToFloatPointer(block.wind)
		return block
	end,
	declarations = get_common_glsl() .. [[
		const float RAIN_MIN_DIAMETER = ]] .. string.format("%.2f", RAIN_MIN_DIAMETER) .. [[;
		const float RAIN_MAX_DIAMETER = ]] .. string.format("%.2f", RAIN_MAX_DIAMETER) .. [[;

		// terminal velocity of a drop of this diameter in mm
		vec3 get_rain_velocity(float diameter) {
			return vec3(rain_data.wind.x, -(9.65 - 10.3 * exp(-0.6 * diameter)), rain_data.wind.z);
		}
	]],
	spawn = [[
		vec3 r = pcg3d_unorm(uvec3(index, generation, 17u));
		vec3 r2 = pcg3d_unorm(uvec3(index, generation, 101u));
		// exponentially distributed sizes above the smallest drawn
		float diameter = min(RAIN_MIN_DIAMETER - log(max(r2.x, 1e-7)) / rain_data.lambda, RAIN_MAX_DIAMETER);
		p.width = diameter * 0.001;
		p.position = get_camera_box_position(r);
		p.velocity = get_rain_velocity(diameter);
		p.life = mix(8.0, 16.0, r2.y);
	]],
	update = [[
		p.velocity = get_rain_velocity(p.width * 1000.0);
		vec3 moved = p.position + p.velocity * dt;
		p.position = wrap_into_camera_box(moved);

		// the box moved it, it did not fall
		if (distance(moved, p.position) > 0.01) particle_previous = p.position;
	]],
	-- a drop that hits something is gone, the slot spawns again
	collision = "shelter_map",
	collide = "p.life = 0.0;",
	visibility = [[
		vec3 surface;
		vec3 normal;
		return particle_probe_shelter_map(p.position, surface, normal) ? 0.0 : 1.0;
	]],
}
precipitation.snow = particles.Register{
	name = "snow",
	max_count = MAX_SNOWFLAKES,
	scatter_g = SNOW_SCATTER_G,
	streak_time = EXPOSURE_TIME,
	fade_time = 0.3,
	fade_near = 1,
	fade_far = BOX_SIZE * 0.5,
	depth_near = 0.3,
	depth_far = BOX_SIZE,
	IsActive = function()
		return enabled:Get() and atmosphere.IsEnabled() and precipitation.snow_rate > 0
	end,
	GetCount = precipitation.GetSnowflakeCount,
	block = {
		{"lambda", "float"},
		{"wetness", "float"},
		{"wind", "vec3"},
	},
	WriteBlock = function(self, block)
		block.lambda = select(2, get_snow_distribution())
		block.wetness = surface_weather.GetSnowWetness()
		atmosphere.GetWind():CopyToFloatPointer(block.wind)
		return block
	end,
	declarations = get_common_glsl() .. [[
		const float SNOW_MIN_MELTED_DIAMETER = ]] .. string.format("%.2f", SNOW_MIN_MELTED_DIAMETER) .. [[;
		const float SNOW_MAX_MELTED_DIAMETER = ]] .. string.format("%.2f", SNOW_MAX_MELTED_DIAMETER) .. [[;
		// seconds a flake lies on the surface before it is gone
		const float SNOW_LAND_TIME = 1.5;
		const float SNOW_DENSITY_SCALE = ]] .. string.format("%.3f", SNOW_DENSITY_SCALE) .. [[;

		// flakes flutter as they fall, a few centimeters to a couple of decimeters every second or two (calibrated,
		// not sourced), the lighter dry ones more. the offset is a function of the age, so it is added as the change
		// over the step and does not drift
		struct SnowSway {
			float angular;
			float amplitude;
			float phase;
		};

		SnowSway get_snow_sway(uint index, uint generation) {
			vec3 r = pcg3d_unorm(uvec3(index, generation, 53u));
			vec3 r2 = pcg3d_unorm(uvec3(index, generation, 211u));
			return SnowSway(mix(2.0, 5.0, r2.y), mix(0.03, 0.2, r2.z) * (1.0 - 0.5 * snow_data.wetness), r.x * 61.0);
		}

		vec3 get_snow_sway_offset(SnowSway s, float t) {
			return s.amplitude * vec3(sin(s.angular * t + s.phase), 0.0, cos(s.angular * 0.7 * t + s.phase));
		}

		vec3 get_snow_sway_velocity(SnowSway s, float t) {
			return s.amplitude * s.angular * vec3(cos(s.angular * t + s.phase), 0.0, -0.7 * sin(s.angular * 0.7 * t + s.phase));
		}

		// unrimed aggregates, wet ones fall faster
		vec3 get_snow_velocity(float diameter) {
			return vec3(snow_data.wind.x, -0.8 * pow(diameter, 0.16) * (1.0 + snow_data.wetness), snow_data.wind.z);
		}
	]],
	spawn = [[
		vec3 r = pcg3d_unorm(uvec3(index, generation, 53u));
		vec3 r2 = pcg3d_unorm(uvec3(index, generation, 211u));
		float melted = min(SNOW_MIN_MELTED_DIAMETER - log(max(r2.x, 1e-7)) / snow_data.lambda, SNOW_MAX_MELTED_DIAMETER);
		// wet flakes stick together into aggregates about twice as big and fast (calibrated, not sourced)
		float diameter = sqrt(melted * melted * melted / SNOW_DENSITY_SCALE) * (1.0 + snow_data.wetness);
		p.width = diameter * 0.001;
		p.position = get_camera_box_position(r);
		p.velocity = get_snow_velocity(diameter);
		p.life = mix(12.0, 24.0, r2.y);
	]],
	update = [[
		// a flake that has landed stays where it is and melts away
		if (p.user.y == 1u) {
			p.velocity = vec3(0.0);

			if (p.age - uintBitsToFloat(p.user.z) >= SNOW_LAND_TIME) p.life = 0.0;

			return;
		}

		SnowSway sway = get_snow_sway(index, p.user.x);
		vec3 velocity = get_snow_velocity(p.width * 1000.0);
		vec3 moved = p.position + velocity * dt + get_snow_sway_offset(sway, p.age) - get_snow_sway_offset(sway, p.age - dt);
		p.position = wrap_into_camera_box(moved);
		p.velocity = velocity + get_snow_sway_velocity(sway, p.age);

		// the box moved it, it did not fall
		if (distance(moved, p.position) > 0.01) particle_previous = p.position;
	]],
	-- a flake comes to rest on the surface (half sunk by its own size) and melts away
	collision = "shelter_map",
	collide = [[
		particle_stick(p, hit, normal);
		p.user.y = 1u;
		p.user.z = floatBitsToUint(p.age);
	]],
	visibility = [[
		// a landed flake melts
		if (p.user.y == 1u) return 1.0 - smoothstep(0.0, SNOW_LAND_TIME, p.age - uintBitsToFloat(p.user.z));

		vec3 surface;
		vec3 normal;
		return particle_probe_shelter_map(p.position, surface, normal) ? 0.0 : 1.0;
	]],
}
return precipitation
