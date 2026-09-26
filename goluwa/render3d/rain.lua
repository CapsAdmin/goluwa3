local render3d = import("goluwa/render3d/render3d.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local surface_weather = import("goluwa/render3d/surface_weather.lua")
-- Falling rain around the camera as streaks, drawn with the translucent surfaces (passes/translucent.lua)
-- so they sort and fog with them. The drops further out are too small to see one by one, they are part
-- of the fog (atmosphere.SetRainRate).
-- No drop is simulated: each one's size, speed and place follow from its index, and it falls through a
-- box that wraps around the camera. Drop sizes follow Marshall and Palmer (1948), their speeds Atlas et
-- al. (1973). A streak is the path a drop covers while the shutter is open, so it covers each point on
-- it for only a drop's width of that path.
local rain = library()
-- mm/h
rain.rate = 0
-- drops per m³ per mm of diameter, at any rain rate
local MARSHALL_PALMER_N0 = 8000
-- mm, smaller drops are only part of the fog
local MIN_DIAMETER = 1
local MAX_DIAMETER = 6
-- m, the width of the box of drops around the camera
local BOX_SIZE = 20
local MAX_DROPS = 131072
-- s, a camera's shutter at 60 fps
local EXPOSURE_TIME = 1 / 60
-- a clear sky adds roughly this much diffuse light to the direct light on a horizontal surface
local CLEAR_SKY_DIFFUSE_RATIO = 0.15
local GROUND_ALBEDO = 0.2

function rain.SetRate(mm_per_hour)
	rain.rate = mm_per_hour
end

function rain.GetRate()
	return rain.rate
end

-- the marshall palmer slope, 1/mm
local function get_lambda()
	return 4.1 * rain.rate ^ -0.21
end

-- how many of the drops the box physically holds are drawn, and how much each drawn one stands for
function rain.GetDropCount()
	local lambda = get_lambda()
	local physical = MARSHALL_PALMER_N0 / lambda * math.exp(-lambda * MIN_DIAMETER) * BOX_SIZE ^ 3
	local drawn = math.min(math.ceil(physical), MAX_DROPS)
	return drawn, physical / drawn
end

rain.block = {
	render3d.camera_block,
	render3d.prev_camera_block,
	{"rain_time", "float"},
	{"rain_dt", "float"},
	{"rain_lambda", "float"},
	{"rain_coverage_scale", "float"},
	{"rain_wind", "vec3"},
	{"rain_sun_direction", "vec3"},
	{"rain_sun_illuminance", "vec3"},
	{"rain_moon_direction", "vec3"},
	{"rain_moon_illuminance", "vec3"},
	{"rain_ambient_radiance", "vec3"},
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
	function rain.WriteBlock(self, block, b0_tex, moments_tex, write_depth_warp)
		render3d.WriteCameraBlock(self, block)
		render3d.WritePreviousCameraBlock(self, block)
		post_source.WritePreExposureBlock(self, block)
		surface_weather.WriteBlock(self, block)
		block.b0_tex = self:GetTextureIndex(b0_tex)
		block.moments_tex = self:GetTextureIndex(moments_tex)
		write_depth_warp(block.depth_warp)
		-- wrapped so the drop positions keep their precision, they jump once when it wraps
		block.rain_time = system.GetElapsedTime() % 1024
		block.rain_dt = system.GetElapsedTime() - render3d.GetPreviousElapsedTime()
		block.rain_lambda = get_lambda()
		block.rain_coverage_scale = select(2, rain.GetDropCount())
		atmosphere.GetWind():CopyToFloatPointer(block.rain_wind)
		-- the light the drops scatter: the sun and the moon through the clouds, and the sky and the
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
		sun_dir:CopyToFloatPointer(block.rain_sun_direction)
		direct_sun:CopyToFloatPointer(block.rain_sun_illuminance)
		moon_dir:CopyToFloatPointer(block.rain_moon_direction)
		direct_moon:CopyToFloatPointer(block.rain_moon_illuminance)
		Vec3(ambient, ambient, ambient):CopyToFloatPointer(block.rain_ambient_radiance)
		return block
	end
end

-- a vertex stage drawing each instance as one streak, a 4 vertex triangle strip
function rain.GetVertexGLSL(block_name)
	return [[
		const float RAIN_BOX_SIZE = ]] .. string.format("%.1f", BOX_SIZE) .. [[;
		const float RAIN_MIN_DIAMETER = ]] .. string.format("%.1f", MIN_DIAMETER) .. [[;
		const float RAIN_MAX_DIAMETER = ]] .. string.format("%.1f", MAX_DIAMETER) .. [[;
		const float RAIN_EXPOSURE_TIME = ]] .. string.format("%.8f", EXPOSURE_TIME) .. [[;
		// geometric optics of a water sphere without its diffraction peak
		const float RAIN_SCATTER_G = 0.81;

		uvec3 rain_pcg3d(uvec3 v) {
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

		float rain_phase(float mu) {
			float gg = RAIN_SCATTER_G * RAIN_SCATTER_G;
			return (1.0 - gg) / (12.566370614 * pow(1.0 + gg - 2.0 * RAIN_SCATTER_G * mu, 1.5));
		}

		// true when a roof or canopy is above the drop along the rain
		bool is_rain_sheltered(vec3 pos) {
			if (]] .. block_name .. [[.rain_occlusion_texture == -1) return false;

			mat4 m = ]] .. block_name .. [[.rain_occlusion_matrix;
			vec4 light_space_pos = m * vec4(pos, 1.0);
			vec3 coords = light_space_pos.xyz / light_space_pos.w;
			coords.xy = coords.xy * 0.5 + 0.5;

			if (any(lessThan(coords, vec3(0.0))) || any(greaterThan(coords, vec3(1.0)))) return false;

			float depth_per_meter = length(vec3(m[0].z, m[1].z, m[2].z));
			return textureLod(TEXTURE(]] .. block_name .. [[.rain_occlusion_texture), coords.xy, 0.0).r < coords.z - 0.05 * depth_per_meter;
		}

		vec2 get_rain_screen_motion(vec3 world_pos, vec3 prev_world_pos) {
			vec4 clip = ]] .. block_name .. [[.projection * ]] .. block_name .. [[.view * vec4(world_pos, 1.0);
			vec4 prev_clip = ]] .. block_name .. [[.prev_projection * ]] .. block_name .. [[.prev_view * vec4(prev_world_pos, 1.0);

			if (clip.w <= 0.0001 || prev_clip.w <= 0.0001) return vec2(0.0);

			return (clip.xy / clip.w - prev_clip.xy / prev_clip.w) * 0.5;
		}

		void main() {
			vec3 r = vec3(rain_pcg3d(uvec3(uint(gl_InstanceIndex), 17u, 29u))) * (1.0 / 4294967296.0);
			vec3 r2 = vec3(rain_pcg3d(uvec3(uint(gl_InstanceIndex), 101u, 7u))) * (1.0 / 4294967296.0);
			// exponentially distributed sizes above the smallest drawn
			float diameter = min(RAIN_MIN_DIAMETER - log(max(r2.x, 1e-7)) / ]] .. block_name .. [[.rain_lambda, RAIN_MAX_DIAMETER);
			float speed = 9.65 - 10.3 * exp(-0.6 * diameter);
			vec3 velocity = vec3(]] .. block_name .. [[.rain_wind.x, -speed, ]] .. block_name .. [[.rain_wind.z);
			vec3 camera = ]] .. block_name .. [[.camera_position;
			// falling through the world, wrapped into the box around the camera
			vec3 fallen = r * RAIN_BOX_SIZE + velocity * ]] .. block_name .. [[.rain_time;
			vec3 head = camera + (fract((fallen - camera) / RAIN_BOX_SIZE + 0.5) - 0.5) * RAIN_BOX_SIZE;
			vec3 tail = head - velocity * RAIN_EXPOSURE_TIME;
			vec3 to_drop = head - camera;
			float dist = length(to_drop);
			// thinned toward the box's edge so drops don't pop in, and none right in front of the eye
			float fade = (1.0 - smoothstep(0.7, 1.0, dist / (RAIN_BOX_SIZE * 0.5))) * smoothstep(0.3, 1.0, dist);

			if (fade <= 0.0 || is_rain_sheltered(head)) {
				gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
				return;
			}

			float width = diameter * 0.001;
			// at least a pixel and a half wide, fainter by as much
			float pixel = dist * 2.0 / (abs(]] .. block_name .. [[.projection[1][1]) * ]] .. block_name .. [[.render_size.y);
			float drawn_width = max(width, pixel * 1.5);
			vec3 axis = head - tail;
			vec3 side = normalize(cross(axis, to_drop));
			// a point on the path is covered while the drop passes it, its width of the path's length
			float alpha = min(width / length(axis), 1.0) * (width / drawn_width) * ]] .. block_name .. [[.rain_coverage_scale * fade;
			int corner = gl_VertexIndex;
			float across = float(corner & 1) * 2.0 - 1.0;
			vec3 position = ((corner >> 1) == 0 ? tail : head) + side * across * drawn_width * 0.5;
			vec3 view_dir = to_drop / dist;
			vec3 radiance = ]] .. block_name .. [[.rain_sun_illuminance * rain_phase(dot(]] .. block_name .. [[.rain_sun_direction, view_dir)) +
				]] .. block_name .. [[.rain_moon_illuminance * rain_phase(dot(]] .. block_name .. [[.rain_moon_direction, view_dir)) +
				]] .. block_name .. [[.rain_ambient_radiance;
			out_position = position;
			out_radiance = radiance;
			out_alpha = min(alpha, 1.0);
			out_across = across;
			out_motion = get_rain_screen_motion(position, position - velocity * ]] .. block_name .. [[.rain_dt);
			gl_Position = ]] .. block_name .. [[.projection * ]] .. block_name .. [[.view * vec4(position, 1.0);
		}
	]]
end

rain.vertex_outputs = {
	{"position", "vec3"},
	{"radiance", "vec3"},
	{"alpha", "float"},
	{"across", "float"},
	{"motion", "vec2"},
}

-- the drop's coverage across the streak, rounder than a flat strip and the same on average
function rain.GetCoverageGLSL()
	return [[
		float get_rain_alpha() {
			return min(in_alpha * 1.5 * (1.0 - in_across * in_across), 1.0);
		}
	]]
end

function rain.IsActive()
	return rain.rate > 0
end

function rain.Draw(pipeline, cmd)
	pipeline:UploadConstants()
	cmd:Draw(4, rain.GetDropCount(), 0, 0)
end

event.AddListener("PreDraw3DTranslucent", "rain", function()
	if not rain.IsActive() then return end

	render3d.ExtendTranslucentDepthRange(0.3, BOX_SIZE)
end)

return rain
