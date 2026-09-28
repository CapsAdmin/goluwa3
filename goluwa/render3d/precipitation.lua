local render3d = import("goluwa/render3d/render3d.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local surface_weather = import("goluwa/render3d/surface_weather.lua")
-- Falling rain and snow around the camera, drawn with the translucent surfaces (passes/translucent.lua)
-- so they sort and fog with them. The particles further out are too small to see one by one, they are
-- part of the fog (atmosphere.SetPrecipitationExtinction).
-- Nothing is simulated: each particle's size, speed and place follow from its index, and it falls through
-- a box that wraps around the camera. A particle is drawn as the path it covers while the shutter is open,
-- so it covers each point on it for only its own width of that path.
-- Rain drop sizes follow Marshall and Palmer (1948), their speeds Atlas et al. (1973).
-- Snowflake sizes follow Gunn and Marshall (1958) by melted diameter, turned into flake diameters with
-- Holroyd's (1971) aggregate density of 0.17/D g/cm³, their speeds Locatelli and Hobbs (1974).
local precipitation = library()
-- mm/h
precipitation.rain_rate = 0
-- mm/h of melted water
precipitation.snow_rate = 0
-- drops per m³ per mm of diameter, at any rain rate
local MARSHALL_PALMER_N0 = 8000
-- mm, smaller drops are only part of the fog
local RAIN_MIN_DIAMETER = 1
local RAIN_MAX_DIAMETER = 6
-- mm of melted diameter
local SNOW_MIN_MELTED_DIAMETER = 0.5
local SNOW_MAX_MELTED_DIAMETER = 3
-- g/cm³ times mm, a flake of diameter D mm has density SNOW_DENSITY_SCALE / D
local SNOW_DENSITY_SCALE = 0.17
-- m, the width of the box of particles around the camera
local BOX_SIZE = 20
local MAX_RAIN_DROPS = 131072
local MAX_SNOWFLAKES = 131072
-- s, a camera's shutter at 60 fps
local EXPOSURE_TIME = 1 / 60
-- a clear sky adds roughly this much diffuse light to the direct light on a horizontal surface
local CLEAR_SKY_DIFFUSE_RATIO = 0.15
local GROUND_ALBEDO = 0.2

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

-- the marshall palmer slope, 1/mm
local function get_rain_lambda()
	return 4.1 * precipitation.rain_rate ^ -0.21
end

-- the gunn marshall intercept, per m³ per mm, and slope, 1/mm
local function get_snow_distribution()
	local rate = precipitation.snow_rate
	return 3800 * rate ^ -0.87, 2.55 * rate ^ -0.48
end

-- how many of the particles the box physically holds are drawn, and how much each drawn one stands for
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

function precipitation.GetSnowflakeCount()
	if precipitation.snow_rate <= 0 then return 0, 0 end

	local n0, lambda = get_snow_distribution()
	return get_drawn(
		n0 / lambda * math.exp(-lambda * SNOW_MIN_MELTED_DIAMETER) * BOX_SIZE ^ 3,
		MAX_SNOWFLAKES
	)
end

-- extinction per km of the air the rain and snow fall through
function precipitation.GetExtinction()
	local extinction = 0

	-- rain dims visible light by 1.076 R^0.67 dB/km at R mm/h (Carbonneau 1998), heavy rain of 25 mm/h
	-- alone brings visibility down to ~2 km
	if precipitation.rain_rate > 0 then
		extinction = extinction + 1.076 * precipitation.rain_rate ^ 0.67 / (10 / math.log(10))
	end

	-- twice the flakes' cross section: the gunn marshall distribution over melted diameters d, each flake
	-- d³ / SNOW_DENSITY_SCALE mm² across. 1 mm/h of dry snow leaves ~800 m of visibility
	if precipitation.snow_rate > 0 then
		local n0, lambda = get_snow_distribution()
		local size_scale = 1 + surface_weather.GetSnowWetness()
		extinction = extinction + 3 * math.pi * n0 * size_scale ^ 2 / (
				SNOW_DENSITY_SCALE * lambda ^ 4
			) * 1e-3
	end

	return extinction
end

precipitation.block = {
	render3d.camera_block,
	render3d.prev_camera_block,
	{"precipitation_time", "float"},
	{"precipitation_dt", "float"},
	{"rain_count", "int"},
	{"rain_lambda", "float"},
	{"rain_coverage_scale", "float"},
	{"snow_lambda", "float"},
	{"snow_coverage_scale", "float"},
	{"snow_wetness", "float"},
	{"precipitation_wind", "vec3"},
	{"precipitation_sun_direction", "vec3"},
	{"precipitation_sun_illuminance", "vec3"},
	{"precipitation_moon_direction", "vec3"},
	{"precipitation_moon_illuminance", "vec3"},
	{"precipitation_ambient_radiance", "vec3"},
	{"b0_tex", "int"},
	{"moments_tex", "int"},
	{"depth_warp", "vec2"},
	post_source.pre_exposure_block,
	surface_weather.block,
}

do
	local function luminance(v)
		return v.x * 0.2126 + v.y * 0.7152 + v.z * 0.0722
	end

	-- the moment textures and write_depth_warp(field) of passes/translucent.lua
	function precipitation.WriteBlock(self, block, b0_tex, moments_tex, write_depth_warp)
		render3d.WriteCameraBlock(self, block)
		render3d.WritePreviousCameraBlock(self, block)
		post_source.WritePreExposureBlock(self, block)
		surface_weather.WriteBlock(self, block)
		block.b0_tex = self:GetTextureIndex(b0_tex)
		block.moments_tex = self:GetTextureIndex(moments_tex)
		write_depth_warp(block.depth_warp)
		-- wrapped so the particle positions keep their precision, they jump once when it wraps
		block.precipitation_time = system.GetElapsedTime() % 1024
		block.precipitation_dt = system.GetElapsedTime() - render3d.GetPreviousElapsedTime()
		block.rain_count, block.rain_coverage_scale = precipitation.GetRainDropCount()
		block.rain_lambda = precipitation.rain_rate > 0 and get_rain_lambda() or 1
		block.snow_coverage_scale = select(2, precipitation.GetSnowflakeCount())
		block.snow_lambda = precipitation.snow_rate > 0 and select(2, get_snow_distribution()) or 1
		block.snow_wetness = surface_weather.GetSnowWetness()
		atmosphere.GetWind():CopyToFloatPointer(block.precipitation_wind)
		-- the light the particles scatter: the sun and the moon through the clouds, and the sky and the
		-- ground around them
		local sky = atmosphere.GetSky()
		local cover = atmosphere.GetCloudCover()
		local sun_dir = sky and sky.sun_direction or Vec3(0, 1, 0)
		local sun = atmosphere.GetTransmittance(sun_dir) * atmosphere.GetSunIlluminance()
		local moon_dir = sky and sky.moon_direction or Vec3(0, -1, 0)
		local moon = atmosphere.GetTransmittance(moon_dir) * (sky and sky.moon_illuminance or 0)
		local direct_sun = sun * (1 - cover)
		local direct_moon = moon * (1 - cover)
		local horizontal = luminance(sun) * math.max(sun_dir.y, 0) + luminance(moon) * math.max(moon_dir.y, 0)
		local sky_irradiance = horizontal * CLEAR_SKY_DIFFUSE_RATIO * (
				1 - cover
			) + atmosphere.GetOvercastLuminance(sun_dir, sky and sky.moon_direction, sky and sky.moon_illuminance) * 7 * math.pi / 9 * cover
		local ground_irradiance = sky_irradiance + horizontal * (1 - cover)
		local ambient = (sky_irradiance + GROUND_ALBEDO * ground_irradiance) / (2 * math.pi)
		sun_dir:CopyToFloatPointer(block.precipitation_sun_direction)
		direct_sun:CopyToFloatPointer(block.precipitation_sun_illuminance)
		moon_dir:CopyToFloatPointer(block.precipitation_moon_direction)
		direct_moon:CopyToFloatPointer(block.precipitation_moon_illuminance)
		Vec3(ambient, ambient, ambient):CopyToFloatPointer(block.precipitation_ambient_radiance)
		return block
	end
end

-- a vertex stage drawing each instance as one particle's path, a 4 vertex triangle strip. the first
-- rain_count instances are rain drops, the rest snowflakes
function precipitation.GetVertexGLSL(block_name)
	return [[
		const float BOX_SIZE = ]] .. string.format("%.1f", BOX_SIZE) .. [[;
		const float RAIN_MIN_DIAMETER = ]] .. string.format("%.2f", RAIN_MIN_DIAMETER) .. [[;
		const float RAIN_MAX_DIAMETER = ]] .. string.format("%.2f", RAIN_MAX_DIAMETER) .. [[;
		const float SNOW_MIN_MELTED_DIAMETER = ]] .. string.format("%.2f", SNOW_MIN_MELTED_DIAMETER) .. [[;
		const float SNOW_MAX_MELTED_DIAMETER = ]] .. string.format("%.2f", SNOW_MAX_MELTED_DIAMETER) .. [[;
		const float SNOW_DENSITY_SCALE = ]] .. string.format("%.3f", SNOW_DENSITY_SCALE) .. [[;
		const float EXPOSURE_TIME = ]] .. string.format("%.8f", EXPOSURE_TIME) .. [[;
		// geometric optics of a water sphere without its diffraction peak
		const float RAIN_SCATTER_G = 0.81;
		// an ice aggregate without its diffraction peak scatters less forward than a drop
		const float SNOW_SCATTER_G = 0.6;

		uvec3 precipitation_pcg3d(uvec3 v) {
			v = v * 1664525u + 1013904223u;
			v.x += v.y * v.z;
			v.y += v.z * v.x;
			v.z += v.x * v.y;
			v ^= v >> 16u;
			v.x += v.y * v.z;
			v.y += v.z * v.x;
			v.z += v.x * v.y;
			return v;
		}

		float precipitation_phase(float mu, float g) {
			float gg = g * g;
			return (1.0 - gg) / (12.566370614 * pow(1.0 + gg - 2.0 * g * mu, 1.5));
		}

		// true when a roof or canopy is above the particle along the falling precipitation
		bool is_precipitation_sheltered(vec3 pos) {
			if (]] .. block_name .. [[.shelter_texture == -1) return false;

			mat4 m = ]] .. block_name .. [[.shelter_matrix;
			vec4 light_space_pos = m * vec4(pos, 1.0);
			vec3 coords = light_space_pos.xyz / light_space_pos.w;
			coords.xy = coords.xy * 0.5 + 0.5;

			if (any(lessThan(coords, vec3(0.0))) || any(greaterThan(coords, vec3(1.0)))) return false;

			float depth_per_meter = length(vec3(m[0].z, m[1].z, m[2].z));
			return textureLod(TEXTURE(]] .. block_name .. [[.shelter_texture), coords.xy, 0.0).r < coords.z - 0.05 * depth_per_meter;
		}

		vec2 get_precipitation_screen_motion(vec3 world_pos, vec3 prev_world_pos) {
			vec4 clip = ]] .. block_name .. [[.projection * ]] .. block_name .. [[.view * vec4(world_pos, 1.0);
			vec4 prev_clip = ]] .. block_name .. [[.prev_projection * ]] .. block_name .. [[.prev_view * vec4(prev_world_pos, 1.0);

			if (clip.w <= 0.0001 || prev_clip.w <= 0.0001) return vec2(0.0);

			return (clip.xy / clip.w - prev_clip.xy / prev_clip.w) * 0.5;
		}

		void main() {
			float time = ]] .. block_name .. [[.precipitation_time;
			vec3 wind = ]] .. block_name .. [[.precipitation_wind;
			bool is_rain = gl_InstanceIndex < ]] .. block_name .. [[.rain_count;
			vec3 r;
			vec3 r2;
			// mm
			float diameter;
			vec3 velocity;
			vec3 fallen;
			float coverage_scale;
			float g;

			if (is_rain) {
				r = vec3(precipitation_pcg3d(uvec3(uint(gl_InstanceIndex), 17u, 29u))) * (1.0 / 4294967296.0);
				r2 = vec3(precipitation_pcg3d(uvec3(uint(gl_InstanceIndex), 101u, 7u))) * (1.0 / 4294967296.0);
				// exponentially distributed sizes above the smallest drawn
				diameter = min(RAIN_MIN_DIAMETER - log(max(r2.x, 1e-7)) / ]] .. block_name .. [[.rain_lambda, RAIN_MAX_DIAMETER);
				velocity = vec3(wind.x, -(9.65 - 10.3 * exp(-0.6 * diameter)), wind.z);
				fallen = r * BOX_SIZE + velocity * time;
				coverage_scale = ]] .. block_name .. [[.rain_coverage_scale;
				g = RAIN_SCATTER_G;
			} else {
				uint index = uint(gl_InstanceIndex - ]] .. block_name .. [[.rain_count);
				r = vec3(precipitation_pcg3d(uvec3(index, 53u, 61u))) * (1.0 / 4294967296.0);
				r2 = vec3(precipitation_pcg3d(uvec3(index, 211u, 3u))) * (1.0 / 4294967296.0);
				// wet flakes stick together into aggregates about twice as big and fast (calibrated, not sourced)
				float wetness = ]] .. block_name .. [[.snow_wetness;
				float melted = min(SNOW_MIN_MELTED_DIAMETER - log(max(r2.x, 1e-7)) / ]] .. block_name .. [[.snow_lambda, SNOW_MAX_MELTED_DIAMETER);
				diameter = sqrt(melted * melted * melted / SNOW_DENSITY_SCALE) * (1.0 + wetness);
				// unrimed aggregates, wet ones fall faster
				float speed = 0.8 * pow(diameter, 0.16) * (1.0 + wetness);
				// flakes flutter as they fall, a few centimeters to a couple of decimeters every second or
				// two (calibrated, not sourced), the lighter dry ones more
				float angular = mix(2.0, 5.0, r2.y);
				float amplitude = mix(0.03, 0.2, r2.z) * (1.0 - 0.5 * wetness);
				float phase = r.x * 61.0;
				vec3 sway = amplitude * vec3(sin(angular * time + phase), 0.0, cos(angular * 0.7 * time + phase));
				vec3 sway_velocity = amplitude * angular * vec3(cos(angular * time + phase), 0.0, -0.7 * sin(angular * 0.7 * time + phase));
				velocity = vec3(wind.x, -speed, wind.z);
				fallen = r * BOX_SIZE + velocity * time + sway;
				velocity += sway_velocity;
				coverage_scale = ]] .. block_name .. [[.snow_coverage_scale;
				g = SNOW_SCATTER_G;
			}

			vec3 camera = ]] .. block_name .. [[.camera_position;
			// falling through the world, wrapped into the box around the camera
			vec3 head = camera + (fract((fallen - camera) / BOX_SIZE + 0.5) - 0.5) * BOX_SIZE;
			vec3 tail = head - velocity * EXPOSURE_TIME;
			vec3 to_particle = head - camera;
			float dist = length(to_particle);
			// thinned toward the box's edge so particles don't pop in, and none right in front of the eye
			float fade = (1.0 - smoothstep(0.7, 1.0, dist / (BOX_SIZE * 0.5))) * smoothstep(0.3, 1.0, dist);

			if (fade <= 0.0 || is_precipitation_sheltered(head)) {
				gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
				return;
			}

			float width = diameter * 0.001;
			// at least a pixel and a half wide, fainter by as much
			float pixel = dist * 2.0 / (abs(]] .. block_name .. [[.projection[1][1]) * ]] .. block_name .. [[.render_size.y);
			float drawn_width = max(width, pixel * 1.5);
			vec3 axis = head - tail;
			float path = length(axis);
			vec3 along_dir = axis / path;
			vec3 side = normalize(cross(axis, to_particle));
			// the path with a round particle at each end, core is the straight part's share of its length
			float core = path / (path + drawn_width);
			// the coverage profile's average over the quad, so rounding the ends doesn't change the total
			float profile_average = core * (2.0 / 3.0) + (1.0 - core) * 0.39269908;
			// a point on the path is covered while the particle passes it, its width of the path's length
			float alpha = width / (path + width) * (width / drawn_width) * coverage_scale * fade;
			int corner = gl_VertexIndex;
			float across = float(corner & 1) * 2.0 - 1.0;
			float along = float(corner >> 1) * 2.0 - 1.0;
			vec3 position = mix(tail, head, along * 0.5 + 0.5) + along_dir * along * drawn_width * 0.5 + side * across * drawn_width * 0.5;
			vec3 view_dir = to_particle / dist;
			vec3 radiance = ]] .. block_name .. [[.precipitation_sun_illuminance * precipitation_phase(dot(]] .. block_name .. [[.precipitation_sun_direction, view_dir), g) +
				]] .. block_name .. [[.precipitation_moon_illuminance * precipitation_phase(dot(]] .. block_name .. [[.precipitation_moon_direction, view_dir), g) +
				]] .. block_name .. [[.precipitation_ambient_radiance;
			out_position = position;
			out_radiance = radiance;
			out_alpha = alpha / profile_average;
			out_shape = vec3(across, along, core);
			out_motion = get_precipitation_screen_motion(position, position - velocity * ]] .. block_name .. [[.precipitation_dt);
			gl_Position = ]] .. block_name .. [[.projection * ]] .. block_name .. [[.view * vec4(position, 1.0);
		}
	]]
end

precipitation.vertex_outputs = {
	{"position", "vec3"},
	{"radiance", "vec3"},
	{"alpha", "float"},
	{"shape", "vec3"},
	{"motion", "vec2"},
}

-- a particle's coverage across its path, round rather than a flat strip and the same on average
function precipitation.GetCoverageGLSL()
	return [[
		float get_precipitation_alpha() {
			float end_distance = max(abs(in_shape.y) - in_shape.z, 0.0) / max(1.0 - in_shape.z, 1e-4);
			return min(in_alpha * max(1.0 - in_shape.x * in_shape.x - end_distance * end_distance, 0.0), 1.0);
		}
	]]
end

function precipitation.IsActive()
	return precipitation.rain_rate > 0 or precipitation.snow_rate > 0
end

function precipitation.Draw(pipeline, cmd)
	pipeline:UploadConstants()
	cmd:Draw(4, precipitation.GetRainDropCount() + precipitation.GetSnowflakeCount(), 0, 0)
end

event.AddListener("PreDraw3DTranslucent", "precipitation", function()
	if not precipitation.IsActive() then return end

	render3d.ExtendTranslucentDepthRange(0.3, BOX_SIZE)
end)

return precipitation
