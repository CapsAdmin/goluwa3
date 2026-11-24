local ffi = require("ffi")
local json = import("goluwa/codecs/json.lua")
local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/filesystem/fs.lua")
local system = import("goluwa/system.lua")
local timer = import("goluwa/timer.lua")
local event = import("goluwa/event.lua")
local Texture = import("goluwa/render/texture.lua")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local planet = import("goluwa/planet.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local clouds = import("goluwa/render3d/clouds.lua")
local weather = import("goluwa/render3d/weather.lua")
local TileSet = import("lua/earth/tile_set.lua")
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

-- cover[channel] = floats of [time][row][column] in 0..1; lat0, lon0 is the south west point
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

-- params: the anchor's basis (east, north, up), its longitude, the radius, the map's size, the grid's south west corner,
-- step and side, the map's texels, then the plane's three channels
local PARAMS = 17
local GROUP = 8
local SHADER = [=[
	float cloud_cover_bspline(float t, int k) {
		float t2 = t * t, t3 = t2 * t;

		if (k == 0) return (1.0 - t) * (1.0 - t) * (1.0 - t) / 6.0;
		if (k == 1) return (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0;
		if (k == 2) return (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0;
		return t3 / 6.0;
	}

	void main() {
		int texels = int(params[16]);
		ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);

		if (pixel.x >= texels || pixel.y >= texels) return;

		float size = params[11];
		vec2 world = (vec2(pixel) + 0.5) / float(texels) * size - size * 0.5;
		float radius = params[10];
		float e = world.x / radius;
		float n = -world.y / radius;
		float u = sqrt(max(1.0 - e * e - n * n, 0.0));
		vec3 v = e * vec3(params[0], params[1], params[2]) + n * vec3(params[3], params[4], params[5]) + u * vec3(params[6], params[7], params[8]);
		float lat = degrees(asin(clamp(v.z, -1.0, 1.0)));
		float lon = degrees(atan(v.y, v.x));
		lon = params[9] + mod(lon - params[9] + 180.0, 360.0) - 180.0;
		float step = params[14];
		int side = int(params[15]);
		float gy = (lat - params[12]) / step;
		float gx = (mod(lon - params[13] + 180.0, 360.0) - 180.0) / step;
		int iy = int(floor(gy));
		int ix = int(floor(gx));
		vec3 value = vec3(0.0);

		for (int j = 0; j < 4; j++) {
			int row = clamp(iy + j - 1, 0, side - 1) * side;
			float wy = cloud_cover_bspline(gy - float(iy), j);

			for (int i = 0; i < 4; i++) {
				int at = ]=] .. PARAMS .. [=[ + row + clamp(ix + i - 1, 0, side - 1);
				value += wy * cloud_cover_bspline(gx - float(ix), i) * vec3(params[at], params[at + side * side], params[at + 2 * side * side]);
			}
		}

		imageStore(out_map, pixel, vec4(clamp(value, 0.0, 1.0), 1.0));
	}
]=]
local pipeline
local param_buffers = {}

local function get_frame_span()
	return math.max(render.GetSwapchainImageCount() or 1, 1)
end

local function get_pipeline()
	pipeline = pipeline or
		EasyPipeline.Compute{
			name = "earth_cloud_cover",
			DescriptorSetCount = get_frame_span(),
			LocalSize = {x = GROUP, y = GROUP, z = 1},
			storage_images = {{binding_index = 0}},
			storage_buffers = {{binding_index = 1}},
			custom_declarations = [=[
				layout(set = 0, binding = 0, rgba8) uniform writeonly image2D out_map;
				layout(set = 0, binding = 1, std430) buffer Params { float params[]; };
			]=],
			shader = SHADER,
		}
	return pipeline
end

-- into this frame's buffer, so frames still in flight keep theirs
local function write_params(slot, time)
	local grid = cloud_cover.grid
	local anchor = cloud_cover.source.Anchor
	local plane = GRID_SIDE * GRID_SIDE
	local buffer = param_buffers[slot]

	if not buffer then
		buffer = render.CreateBuffer{
			byte_size = (PARAMS + plane * 3) * 4,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "earth cloud cover",
		}
		param_buffers[slot] = buffer
	end

	local params = ffi.cast("float *", buffer:Map())
	params[0], params[1], params[2] = anchor.ex, anchor.ey, anchor.ez
	params[3], params[4], params[5] = anchor.nx, anchor.ny, anchor.nz
	params[6], params[7], params[8] = anchor.ux, anchor.uy, anchor.uz
	params[9], params[10], params[11] = anchor.lon, planet.RADIUS, MAP_SIZE
	params[12], params[13], params[14], params[15], params[16] = grid.lat0, grid.lon0, GRID_STEP, GRID_SIDE, MAP_TEXELS
	local times = grid.times
	local t = 1

	while t < #times - 1 and times[t + 1] <= time do
		t = t + 1
	end

	local ft = math.clamp((time - times[t]) / (times[t + 1] - times[t]), 0, 1)

	for channel = 1, 3 do
		local v = grid.cover[channel]
		local out = params + PARAMS + (channel - 1) * plane

		for i = 0, plane - 1 do
			out[i] = v[(t - 1) * plane + i] * (1 - ft) + v[t * plane + i] * ft
		end
	end

	return buffer
end

local function draw_map()
	local time = cloud_cover.draw_time
	local cmd = time and render.GetCommandBuffer()

	if not cmd then return end

	local slot = ((render.GetCurrentFrame() or 1) - 1) % get_frame_span() + 1
	local p = get_pipeline()
	local buffer = write_params(slot, time)
	local texture = cloud_cover.texture
	render.TransitionResourceToComputeStorage(texture, {cmd = cmd})
	p:UpdateDescriptorSet("storage_image", slot, 0, 0, texture:GetView())
	p:UpdateDescriptorSet("storage_buffer", slot, 1, 0, buffer, buffer:GetSize())
	p.pipeline:Dispatch(cmd, math.ceil(MAP_TEXELS / GROUP), math.ceil(MAP_TEXELS / GROUP), 1, slot)
	render.TransitionResource(
		texture,
		"shader_read_only_optimal",
		{
			cmd = cmd,
			srcStage = "compute",
			srcAccess = "shader_write",
			dstStage = "all_commands",
			dstAccess = "shader_read",
		}
	)
	clouds.SetCoverageMap(texture, -MAP_SIZE / 2, -MAP_SIZE / 2, MAP_SIZE)
	cloud_cover.draw_time = nil
end

local function build_map()
	cloud_cover.draw_time = weather.GetTime()
	cloud_cover.built_time = cloud_cover.draw_time
end

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
		image = {usage = {"storage", "sampled"}},
	}
	weather.SetCloudLayers(cloud_cover.LAYERS)
	refetch()
	event.AddListener("Update", "earth_cloud_cover", update)
	event.AddListener("PreRenderPass", "earth_cloud_cover", draw_map)
end

function cloud_cover.SetSource(source)
	cloud_cover.source = source
	refetch()
end

function cloud_cover.Stop()
	event.RemoveListener("Update", "earth_cloud_cover")
	event.RemoveListener("PreRenderPass", "earth_cloud_cover")

	if cloud_cover.texture then
		clouds.SetCoverageMap(nil)
		cloud_cover.texture:Remove()
		cloud_cover.texture = nil
	end

	cloud_cover.source = nil
	cloud_cover.coverage = nil
end

return cloud_cover
