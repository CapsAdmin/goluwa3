local ffi = require("ffi")
local Vec3 = import("goluwa/structs/vec3.lua")
local Texture = import("goluwa/render/texture.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local clouds = import("goluwa/render3d/clouds.lua")
local weather = import("goluwa/render3d/weather.lua")
local skybox_estimate = {}
local WIDTH = 96
local HEIGHT = 24
local SUN_EXCLUSION = math.rad(4)
local CLOUD_RESIDUAL_SCALE = 2.5
local CLOUD_RESIDUAL_MIN = 0.1
local LUMINANCE_WEIGHT = 0.25
local SUN_VISIBLE_PEAK = 10
local SUN_VISIBLE_RANGE = 6
local REFERENCE_SHARE = 0.4
local ELEVATION_MIN = -6
local ELEVATION_STEP = 2
local ELEVATION_COUNT = 44
local VISIBILITIES = {4000, 8000, 15000, 30000, 60000, 120000, 240000}
local DoubleArray = ffi.typeof("double[?]")
local FloatPointer = ffi.typeof("const float *")
-- the sample grid: azimuth across, elevation 0 to 90 degrees up
local GRID_GLSL = (
	[[
	vec3 get_grid_dir(int index) {
		float azimuth = (float(index %% %d) + 0.5) / %d.0 * 6.28318531;
		float elevation = (float(index / %d) + 0.5) / %d.0 * 1.57079633;
		return vec3(cos(elevation) * cos(azimuth), sin(elevation), cos(elevation) * sin(azimuth));
	}
]]
):format(WIDTH, WIDTH, WIDTH, HEIGHT)
local Constants = ffi.typeof([[struct {
	float yaw[2];
	float lod;
	int cube_index;
}]])
local DECLARATIONS = [[
	layout(push_constant) uniform SkyboxSampleConstants {
		vec2 yaw;
		float lod;
		int cube_index;
	} skybox_sample;
]]
local SAMPLE_GLSL = GRID_GLSL .. (
		[[
	vec4 shade(vec2 uv, vec3 _cube_dir) {
		vec3 dir = get_grid_dir(int(uv.x * %d.0) + int(uv.y * %d.0) * %d);
		vec2 yaw = skybox_sample.yaw;
		vec3 d = vec3(dir.x * yaw.x - dir.z * yaw.y, dir.y, dir.x * yaw.y + dir.z * yaw.x);
		return vec4(textureLod(CUBEMAP(skybox_sample.cube_index), vec3(-d.z, -d.x, d.y), skybox_sample.lod).rgb, 1.0);
	}
]]
	):format(WIDTH, HEIGHT, WIDTH)

local function get_direction(index)
	local azimuth = (index % WIDTH + 0.5) / WIDTH * 2 * math.pi
	local elevation = (math.floor(index / WIDTH) + 0.5) / HEIGHT * 0.5 * math.pi
	return Vec3(
		math.cos(elevation) * math.cos(azimuth),
		math.sin(elevation),
		math.cos(elevation) * math.sin(azimuth)
	),
	elevation
end

local function sample_skybox(cube, lod)
	local target = Texture.New{
		width = WIDTH,
		height = HEIGHT,
		format = "r32g32b32a32_sfloat",
		mip_map_levels = 1,
	}
	target:Shade(
		SAMPLE_GLSL,
		{
			textures = {cube},
			custom_declarations = DECLARATIONS,
			fragment_push_constants = {
				size = ffi.sizeof(Constants),
				get_data = function(_, _, pipeline)
					local yaw = atmosphere.GetSkyboxYaw()
					return Constants({math.cos(yaw), math.sin(yaw)}, lod, pipeline:GetCubeMapTextureIndex(cube))
				end,
			},
		}
	)
	local pixels = ffi.cast(FloatPointer, target:Download():Resolve().pixels)
	local samples = {log_rgb = DoubleArray(WIDTH * HEIGHT * 3)}

	for index = 0, WIDTH * HEIGHT - 1 do
		local r, g, b = pixels[index * 4], pixels[index * 4 + 1], pixels[index * 4 + 2]
		local dir, elevation = get_direction(index)
		samples[index + 1] = {
			dir = dir,
			weight = math.cos(elevation),
			luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b,
		}
		samples.log_rgb[index * 3] = math.log(math.max(r, 1e-9))
		samples.log_rgb[index * 3 + 1] = math.log(math.max(g, 1e-9))
		samples.log_rgb[index * 3 + 2] = math.log(math.max(b, 1e-9))
	end

	target:Remove()
	return samples
end

local function find_sun(samples)
	local sorted = {}

	for i, sample in ipairs(samples) do
		sorted[i] = sample
	end

	table.sort(sorted, |a,b|->a.luminance > b.luminance)
	local sum = Vec3(0, 0, 0)

	for i = 1, math.max(math.floor(#sorted * 0.002), 1) do
		sum = sum + sorted[i].dir * sorted[i].luminance
	end

	return sum:GetNormalized(),
	sorted[1].luminance / math.max(sorted[math.floor(#sorted / 2)].luminance, 1e-9)
end

-- one row per candidate sun elevation, one column per sample direction, for the current aerosol
local CANDIDATE_GLSL = GRID_GLSL .. (
		[[
	vec3 get_sky_ray(vec2 uv, out vec3 sun_dir) {
		float elevation = radians(%f + float(int(uv.y * %d.0)) * %f);
		vec2 azimuth = sky_view.sun_direction.xz;
		sun_dir = vec3(cos(elevation) * azimuth.x, sin(elevation), cos(elevation) * azimuth.y);
		return get_grid_dir(int(uv.x * %d.0));
	}
]]
	):format(ELEVATION_MIN, ELEVATION_COUNT, ELEVATION_STEP, WIDTH * HEIGHT)

local function shade_candidates(target, sun_azimuth)
	atmosphere.ShadeSkyRadiance(target, CANDIDATE_GLSL, Vec3(math.sin(sun_azimuth), 0, math.cos(sun_azimuth)))
	local pixels = ffi.cast(FloatPointer, target:Download():Resolve().pixels)
	local rows = {}

	for row = 0, ELEVATION_COUNT - 1 do
		local sky = DoubleArray(WIDTH * HEIGHT * 3)

		for index = 0, WIDTH * HEIGHT - 1 do
			local p = (row * WIDTH * HEIGHT + index) * 4

			for c = 0, 2 do
				sky[index * 3 + c] = math.log(math.max(pixels[p + c], 1e-9))
			end
		end

		rows[row + 1] = sky
	end

	return rows
end

local function fit(samples, sky, clear)
	local log_rgb = samples.log_rgb
	local weight_sum, offset = 0, 0

	for i, sample in ipairs(samples) do
		if clear[i] then
			local j = (i - 1) * 3
			offset = offset + sample.weight * (
					(
						log_rgb[j] - sky[j]
					) + (
						log_rgb[j + 1] - sky[j + 1]
					) + (
						log_rgb[j + 2] - sky[j + 2]
					)
				) / 3
			weight_sum = weight_sum + sample.weight
		end
	end

	offset = offset / weight_sum
	local error = 0
	local residuals = {}

	for i, sample in ipairs(samples) do
		local j = (i - 1) * 3
		local r = log_rgb[j] - sky[j] - offset
		local g = log_rgb[j + 1] - sky[j + 1] - offset
		local b = log_rgb[j + 2] - sky[j + 2] - offset
		local l = (r + g + b) / 3
		local residual = math.sqrt(((r - l) ^ 2 + (g - l) ^ 2 + (b - l) ^ 2) / 3 + LUMINANCE_WEIGHT * l * l)
		residuals[i] = residual

		if clear[i] then error = error + sample.weight * residual * residual end
	end

	return math.sqrt(error / weight_sum), offset, residuals
end

-- sun_direction, when known (a map's sun), replaces the painted sun found in the skybox
function skybox_estimate.Estimate(cube, sun_direction)
	local samples = sample_skybox(cube, 2)
	local sun_dir, sun_peak = find_sun(samples)
	sun_dir = sun_direction or sun_dir
	local sun_azimuth = math.atan2(sun_dir.x, sun_dir.z)
	local sun_elevation = math.deg(math.asin(sun_dir.y))
	local sun_visible = sun_direction ~= nil or sun_peak >= SUN_VISIBLE_PEAK
	local clear = {}
	local usable = {}
	local usable_weight = 0
	local blueness = {}

	for i, sample in ipairs(samples) do
		usable[i] = math.acos(math.clamp(sample.dir:GetDot(sun_dir), -1, 1)) > SUN_EXCLUSION
		usable_weight = usable_weight + (usable[i] and sample.weight or 0)

		if usable[i] then
			blueness[#blueness + 1] = samples.log_rgb[(i - 1) * 3 + 2] - samples.log_rgb[(i - 1) * 3]
		end
	end

	-- the clear sky is fitted to the bluest part of the sky, so clouds and grey grading are not explained as haze
	table.sort(blueness)
	local blueness_threshold = blueness[math.max(math.floor(#blueness * (1 - REFERENCE_SHARE)), 1)]
	local reference = {}

	for i in ipairs(samples) do
		reference[i] = usable[i] and
			samples.log_rgb[(
				i - 1
			) * 3 + 2] - samples.log_rgb[(
				i - 1
			) * 3] >= blueness_threshold
		clear[i] = reference[i]
	end

	local target = Texture.New{
		width = WIDTH * HEIGHT,
		height = ELEVATION_COUNT,
		format = "r32g32b32a32_sfloat",
		mip_map_levels = 1,
	}
	local old_visibility = atmosphere.GetAerosolVisibility()
	local candidates = {}

	for _, visibility in ipairs(VISIBILITIES) do
		atmosphere.SetAerosolVisibility(visibility)

		for row, sky in ipairs(shade_candidates(target, sun_azimuth)) do
			candidates[#candidates + 1] = {
				visibility = visibility,
				elevation = ELEVATION_MIN + (row - 1) * ELEVATION_STEP,
				sky = sky,
			}
		end
	end

	atmosphere.SetAerosolVisibility(old_visibility)
	target:Remove()
	local best

	for _ = 1, 3 do
		best = nil

		for _, candidate in ipairs(candidates) do
			local error, offset, residuals = fit(samples, candidate.sky, clear)

			if
				(
					not sun_visible or
					math.abs(candidate.elevation - sun_elevation) <= SUN_VISIBLE_RANGE
				)
				and
				(
					not best or
					error < best.error
				)
			then
				best = {candidate = candidate, error = error, offset = offset, residuals = residuals}
			end
		end

		local sorted = {}

		for i in ipairs(samples) do
			if usable[i] then sorted[#sorted + 1] = best.residuals[i] end
		end

		table.sort(sorted)
		local threshold = math.max(sorted[math.ceil(#sorted / 2)] * CLOUD_RESIDUAL_SCALE, CLOUD_RESIDUAL_MIN)

		for i in ipairs(samples) do
			clear[i] = reference[i] and best.residuals[i] < threshold
		end

		best.threshold = threshold
	end

	local cloud_weight = 0

	for i, sample in ipairs(samples) do
		if usable[i] and best.residuals[i] >= best.threshold then
			cloud_weight = cloud_weight + sample.weight
		end
	end

	return {
		sun_direction = sun_dir,
		sun_elevation = sun_elevation,
		sun_visible = sun_visible,
		sun_azimuth = math.deg(sun_azimuth) % 360,
		sun_peak = sun_peak,
		fitted_elevation = best.candidate.elevation,
		fitted_sun_direction = Vec3(
			math.cos(math.rad(best.candidate.elevation)) * math.sin(sun_azimuth),
			math.sin(math.rad(best.candidate.elevation)),
			math.cos(math.rad(best.candidate.elevation)) * math.cos(sun_azimuth)
		),
		aerosol_visibility = best.candidate.visibility,
		intensity = math.exp(-best.offset),
		error = best.error,
		cloud_fraction = cloud_weight / usable_weight,
		samples = samples,
		clear = clear,
		usable = usable,
	}
end

do
	-- clouds have texture and clear sky, painted or not, is smooth: the cloud measure is the log luminance difference
	-- between a fine and a coarse mip, averaged over a ring of nearby directions
	local MASK_GLSL = [[
		float get_skybox_luminance(vec3 dir, float lod) {
			vec2 yaw = skybox_mask.yaw;
			vec3 d = vec3(dir.x * yaw.x - dir.z * yaw.y, dir.y, dir.x * yaw.y + dir.z * yaw.x);
			return log(max(dot(textureLod(CUBEMAP(skybox_mask.cube_index), vec3(-d.z, -d.x, d.y), lod).rgb, vec3(0.2126, 0.7152, 0.0722)), 1e-9));
		}

		float get_detail(vec3 dir) {
			return abs(get_skybox_luminance(dir, skybox_mask.lods.x) - get_skybox_luminance(dir, skybox_mask.lods.y));
		}

		vec4 shade(vec2 uv, vec3 _cube_dir) {
			vec3 dir = normalize(vec3((uv.x - 0.5) * skybox_mask.size, skybox_mask.height, (uv.y - 0.5) * skybox_mask.size));
			vec3 tangent = normalize(cross(dir, abs(dir.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
			vec3 bitangent = cross(dir, tangent);
			float detail = get_detail(dir);

			for (int i = 0; i < 8; i++) {
				float angle = float(i) * 0.78539816;
				detail += get_detail(normalize(dir + (tangent * cos(angle) + bitangent * sin(angle)) * skybox_mask.ring));
			}

			float cloud = smoothstep(skybox_mask.detail.x, skybox_mask.detail.y, detail / 9.0);
			float elevation = degrees(asin(dir.y));
			float sun = degrees(acos(clamp(dot(dir, skybox_mask.sun_direction), -1.0, 1.0)));
			float trust = smoothstep(skybox_mask.min_elevation, skybox_mask.min_elevation + 5.0, elevation) * smoothstep(skybox_mask.sun_exclusion, skybox_mask.sun_exclusion * 2.0, sun);
			return vec4(mix(skybox_mask.fallback, cloud, trust), trust, cloud, 1.0);
		}
	]]
	local Constants = ffi.typeof([[struct {
		float sun_direction[3];
		float size;
		float yaw[2];
		float detail[2];
		float lods[2];
		float ring;
		float height;
		float min_elevation;
		float sun_exclusion;
		float fallback;
		int cube_index;
	}]])
	local DECLARATIONS = [[
		layout(push_constant, scalar) uniform SkyboxMaskConstants {
			vec3 sun_direction;
			float size;
			vec2 yaw;
			vec2 detail;
			vec2 lods;
			float ring;
			float height;
			float min_elevation;
			float sun_exclusion;
			float fallback;
			int cube_index;
		} skybox_mask;
	]]
	local RESOLUTION = 256
	local MIN_ELEVATION = 5
	local DETAIL = {0.015, 0.06}
	-- the fine and coarse scales compared, as the angle one texel spans
	local DETAIL_SCALES = {math.rad(0.18), math.rad(5.6)}
	local RING = math.rad(3)

	-- coverage (r), how much of it the skybox decides (g) and the raw cloud measure (b) on a square of size meters around
	-- the origin, for a cloud base height meters up; where the skybox cannot decide it falls back to the mean coverage
	function skybox_estimate.BuildCoverageMap(cube, sun_direction, height)
		local size = 2 * height / math.tan(math.rad(MIN_ELEVATION))
		local face_texels = cube:GetWidth()
		local lods = {}

		for i, angle in ipairs(DETAIL_SCALES) do
			lods[i] = math.max(math.log(face_texels * angle / (math.pi / 2)) / math.log(2), 0)
		end

		local map = Texture.New{
			width = RESOLUTION,
			height = RESOLUTION,
			format = "r16g16b16a16_sfloat",
			mip_map_levels = 1,
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
		local fallback = 0

		local function shade_mask()
			map:Shade(
				MASK_GLSL,
				{
					textures = {cube},
					custom_declarations = DECLARATIONS,
					fragment_push_constants = {
						size = ffi.sizeof(Constants),
						get_data = function(_, _, pipeline)
							local yaw = atmosphere.GetSkyboxYaw()
							return Constants(
								{sun_direction.x, sun_direction.y, sun_direction.z},
								size,
								{math.cos(yaw), math.sin(yaw)},
								DETAIL,
								lods,
								RING,
								height,
								MIN_ELEVATION,
								math.deg(SUN_EXCLUSION),
								fallback,
								pipeline:GetCubeMapTextureIndex(cube)
							)
						end,
					},
				}
			)
		end

		shade_mask()
		local pixels = map:Download():Resolve()
		local covered, weight = 0, 0

		for y = 0, RESOLUTION - 1 do
			for x = 0, RESOLUTION - 1 do
				local _, trust, cloud = pixels:GetPixelFloat(x, y)
				local px, pz = ((x + 0.5) / RESOLUTION - 0.5) * size, ((y + 0.5) / RESOLUTION - 0.5) * size
				local solid_angle = height / (px * px + pz * pz + height * height) ^ 1.5
				covered = covered + cloud * trust * solid_angle
				weight = weight + trust * solid_angle
			end
		end

		fallback = covered / weight
		shade_mask()
		return map, size, fallback
	end
end

-- engine clouds laid out like the skybox's: one layer reading the coverage map, replacing the cloud layers
function skybox_estimate.ApplyClouds(cube, sun_direction, height, thickness)
	local map, size, fraction = skybox_estimate.BuildCoverageMap(cube, sun_direction, height)
	skybox_estimate.ClearClouds()
	skybox_estimate.cloud_map = map
	clouds.SetCoverageMap(map, -size / 2, -size / 2, size)
	weather.SetCloudLayers{
		{
			name = "skybox",
			bottom = height,
			thickness = thickness,
			coverage = fraction,
			map_channel = 1,
		},
	}
	return fraction
end

function skybox_estimate.ClearClouds()
	if not skybox_estimate.cloud_map then return end

	clouds.SetCoverageMap(nil)
	skybox_estimate.cloud_map:Remove()
	skybox_estimate.cloud_map = nil
end

return skybox_estimate
