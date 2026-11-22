local ffi = require("ffi")
local json = import("goluwa/codecs/json.lua")
local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/filesystem/fs.lua")
local system = import("goluwa/system.lua")
local timer = import("goluwa/timer.lua")
local event = import("goluwa/event.lua")
local Texture = import("goluwa/render/texture.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local clouds = import("goluwa/render3d/clouds.lua")
local weather = import("goluwa/render3d/weather.lua")
local TileSet = import("lua/earth/tile_set.lua")
-- the cloud cover of a weather model (Open-Meteo: low, mid and high cloud in percent, hourly) on a lat/lon grid around
-- the origin, drawn into the clouds' coverage map; the procedural clouds add the shapes
local cloud_cover = {}
cloud_cover.ATTRIBUTION = "Weather: Open-Meteo.com (CC BY 4.0)"
cloud_cover.LAYERS = {
	{
		name = "low",
		bottom = 1200,
		thickness = 1600,
		coverage = 0.3,
		density = 0.07,
		type = 1,
		detail_scale = 250,
		base_variation = 200,
		variation = 0.3,
		map_channel = 1,
	},
	{
		name = "mid",
		bottom = 3800,
		thickness = 1000,
		coverage = 0.2,
		density = 0.04,
		type = 1,
		weather_scale = 30000,
		shape_scale = 2000,
		detail_scale = 150,
		variation = 0.3,
		map_channel = 2,
	},
	{
		name = "high",
		bottom = 9000,
		thickness = 400,
		coverage = 0.2,
		density = 0.25,
		flat = true,
		weather_scale = 30000,
		shape_scale = 6000,
		wind_scale = 6,
		variation = 0.3,
		map_channel = 3,
	},
}
local URL = "https://api.open-meteo.com/v1/forecast"
local HOST_LIMIT = 2
local GRID_STEP = 1.5
local GRID_RADIUS = 10
local GRID_SIDE = GRID_RADIUS * 2 + 1
local BATCH = 125
-- open-meteo counts every location as a call, about 600 a minute for free: a failed batch waits and asks again
local RETRY_SECONDS = 45
local ATTEMPTS = 3
local CACHE_SECONDS = 3 * 3600
local REFETCH_DEGREES = 4
local MAP_TEXELS = 160
local MAP_SIZE = 3200000
local REBUILD_SECONDS = 300
local LAYER_UPDATE_INTERVAL = 10
local directory = vfs.GetStorageDirectory("cache") .. "earth/open_meteo/"
local FloatArray = ffi.typeof("float[?]")

-- grid: lat0, lon0 (its south west point), times (unix seconds), cover[channel] = floats of [time][row][column] in 0..1
local function parse_responses(lat0, lon0, bodies)
	local grid = {lat0 = lat0, lon0 = lon0, cover = {}}
	local points = {}

	for _, body in ipairs(bodies) do
		local decoded = json.decode(body)

		for _, point in ipairs(decoded[1] and decoded or {decoded}) do
			points[#points + 1] = point
		end
	end

	assert(#points == GRID_SIDE * GRID_SIDE, "open-meteo answered " .. #points .. " points")
	grid.times = points[1].hourly.time
	local count = #grid.times

	for channel, key in ipairs{"cloud_cover_low", "cloud_cover_mid", "cloud_cover_high"} do
		local values = FloatArray(count * GRID_SIDE * GRID_SIDE)

		for p, point in ipairs(points) do
			local series = point.hourly[key]

			for t = 1, count do
				values[(t - 1) * GRID_SIDE * GRID_SIDE + p - 1] = (series[t] or 0) / 100
			end
		end

		grid.cover[channel] = values
	end

	return grid
end

local function cache_path(lat0, lon0, time)
	return string.format(
		"%s%g_%g_%g_%d.json",
		directory,
		lat0,
		lon0,
		GRID_STEP,
		math.floor(time / CACHE_SECONDS)
	)
end

local function fetch(lat0, lon0, callback)
	local path = cache_path(lat0, lon0, os.time())
	local cached = fs.read_file(path)

	if cached then
		return callback(parse_responses(lat0, lon0, json.decode(cached)))
	end

	local lats, lons = {}, {}

	for row = 0, GRID_SIDE - 1 do
		for column = 0, GRID_SIDE - 1 do
			lats[#lats + 1] = string.format("%.2f", math.clamp(lat0 + row * GRID_STEP, -89.9, 89.9))
			lons[#lons + 1] = string.format("%.2f", (lon0 + column * GRID_STEP + 180) % 360 - 180)
		end
	end

	local bodies = {}
	local batches = math.ceil(#lats / BATCH)
	local left = batches

	local function request(b, attempt)
		local first, last = (b - 1) * BATCH + 1, math.min(b * BATCH, #lats)
		local url = URL .. "?latitude=" .. table.concat(lats, ",", first, last) .. "&longitude=" .. table.concat(lons, ",", first, last) .. "&hourly=cloud_cover_low,cloud_cover_mid,cloud_cover_high&past_days=1&forecast_days=2&timeformat=unixtime"

		local function retry(reason)
			if attempt >= ATTEMPTS then
				llog("earth: open-meteo failed, the clouds stay procedural: %s", tostring(reason))
				return
			end

			timer.Delay(RETRY_SECONDS, function()
				request(b, attempt + 1)
			end)
		end

		TileSet.HostRequest(
			url,
			{},
			HOST_LIMIT,
			function(response)
				if response.code ~= 200 then return retry("http " .. tostring(response.code)) end

				bodies[b] = response.body
				left = left - 1

				if left > 0 then return end

				fs.create_directory_recursive(directory)
				fs.write_file(path, json.encode(bodies))
				callback(parse_responses(lat0, lon0, bodies))
			end,
			retry
		)
	end

	for b = 1, batches do
		request(b, 1)
	end
end

local function bspline(t)
	local t2, t3 = t * t, t * t * t
	return (1 - t) ^ 3 / 6,
	(3 * t3 - 6 * t2 + 4) / 6,
	(-3 * t3 + 3 * t2 + 3 * t + 1) / 6,
	t3 / 6
end

-- the cover of every channel at a latitude, longitude and time: a cubic b-spline over the grid (the points are a model's
-- cells sampled a degree apart, bilinear between them shows the cells from orbit), linear in time
local function sample(grid, lat, lon, time, out)
	local times = grid.times
	local count = #times
	local t = 1

	while t < count - 1 and times[t + 1] <= time do
		t = t + 1
	end

	local ft = math.clamp((time - times[t]) / (times[t + 1] - times[t]), 0, 1)
	local gy = (lat - grid.lat0) / GRID_STEP
	local gx = ((lon - grid.lon0 + 180) % 360 - 180) / GRID_STEP
	local iy, ix = math.floor(gy), math.floor(gx)
	local wy = {bspline(gy - iy)}
	local wx = {bspline(gx - ix)}
	local plane = GRID_SIDE * GRID_SIDE

	for channel = 1, 3 do
		local v = grid.cover[channel]
		local value = 0

		for k = 0, 1 do
			local base = (t - 1 + k) * plane
			local here = 0

			for j = 0, 3 do
				local row = math.clamp(iy + j - 1, 0, GRID_SIDE - 1) * GRID_SIDE

				for i = 0, 3 do
					here = here + v[base + row + math.clamp(ix + i - 1, 0, GRID_SIDE - 1)] * wy[j + 1] * wx[i + 1]
				end
			end

			value = value + here * (k == 0 and 1 - ft or ft)
		end

		out[channel] = math.clamp(value, 0, 1)
	end

	return out
end

local function build_map()
	local grid = cloud_cover.grid
	local source = cloud_cover.source
	local time = weather.GetTime()
	local pixels = ffi.new("uint8_t[?]", MAP_TEXELS * MAP_TEXELS * 4)
	local value = {}

	for row = 0, MAP_TEXELS - 1 do
		local z = (row + 0.5) / MAP_TEXELS * MAP_SIZE - MAP_SIZE / 2

		for column = 0, MAP_TEXELS - 1 do
			local x = (column + 0.5) / MAP_TEXELS * MAP_SIZE - MAP_SIZE / 2
			local lat, lon = source:WorldToLatLon(x, z)
			sample(grid, lat, lon, time, value)
			local o = (row * MAP_TEXELS + column) * 4
			pixels[o] = math.floor(value[1] * 255 + 0.5)
			pixels[o + 1] = math.floor(value[2] * 255 + 0.5)
			pixels[o + 2] = math.floor(value[3] * 255 + 0.5)
			pixels[o + 3] = 255
		end
	end

	cloud_cover.texture:Upload(pixels)
	clouds.SetCoverageMap(cloud_cover.texture, -MAP_SIZE / 2, -MAP_SIZE / 2, MAP_SIZE)
	cloud_cover.built_time = time
end

-- the layers' own coverage is the cover over the camera: what the sky light, the shadow fallback and the estimates use
local function update_layers()
	local position = render3d.GetCamera():GetPosition()
	local lat, lon = cloud_cover.source:WorldToLatLon(position.x, position.z)
	local value = sample(cloud_cover.grid, lat, lon, weather.GetTime(), {})
	local previous = cloud_cover.coverage
	local changed = not previous
	local layers = {}
	local coverage = {}

	for i, layer in ipairs(cloud_cover.LAYERS) do
		layers[i] = table.copy(layer)
		layers[i].coverage = value[layer.map_channel]
		coverage[i] = layers[i].coverage
		changed = changed or math.abs(coverage[i] - previous[i]) > 0.02
	end

	if not changed then return end

	cloud_cover.coverage = coverage
	weather.SetCloudLayers(layers)
end

local next_layer_update = 0

local function update()
	if not cloud_cover.grid then return end

	if
		not cloud_cover.built_time or
		math.abs(weather.GetTime() - cloud_cover.built_time) > REBUILD_SECONDS
	then
		build_map()
		next_layer_update = 0
	end

	local now = system.GetElapsedTime()

	if now >= next_layer_update then
		next_layer_update = now + LAYER_UPDATE_INTERVAL
		update_layers()
	end
end

-- fetches the grid around the source's anchor unless the one it has is near enough, and draws the map again
local function refetch()
	local lat, lon = cloud_cover.source.Anchor.lat, cloud_cover.source.Anchor.lon
	local grid = cloud_cover.grid
	cloud_cover.built_time = nil

	if
		grid and
		math.abs(grid.lat0 + GRID_RADIUS * GRID_STEP - lat) < REFETCH_DEGREES and
		math.abs((grid.lon0 + GRID_RADIUS * GRID_STEP - lon + 180) % 360 - 180) < REFETCH_DEGREES
	then
		return
	end

	fetch(math.floor(lat + 0.5) - GRID_RADIUS * GRID_STEP, math.floor(lon + 0.5) - GRID_RADIUS * GRID_STEP, function(fetched)
		cloud_cover.grid = fetched
		cloud_cover.built_time = nil
	end)
end

function cloud_cover.Start(source)
	cloud_cover.Stop()
	cloud_cover.source = source
	cloud_cover.texture = Texture.New{
		width = MAP_TEXELS,
		height = MAP_TEXELS,
		format = "r8g8b8a8_unorm",
		mip_map_levels = 1,
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
		image = {usage = {"sampled", "transfer_dst"}},
	}
	weather.SetCloudLayers(cloud_cover.LAYERS)
	refetch()
	event.AddListener("Update", "earth_cloud_cover", update)
end

-- the origin moved: the map is drawn again in the new frame, from a new grid when the old one is too far
function cloud_cover.SetSource(source)
	cloud_cover.source = source
	refetch()
end

function cloud_cover.Stop()
	event.RemoveListener("Update", "earth_cloud_cover")

	if cloud_cover.texture then
		clouds.SetCoverageMap(nil)
		cloud_cover.texture:Remove()
		cloud_cover.texture = nil
	end

	cloud_cover.source = nil
	cloud_cover.coverage = nil
end

return cloud_cover
