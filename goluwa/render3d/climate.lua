local event = import("goluwa/event.lua")
local commands = import("goluwa/cli/commands.lua")
local weather = import("goluwa/render3d/weather.lua")
local clouds = import("goluwa/render3d/clouds.lua")
local climate = library()
--[[
	Named weather: the clouds, what falls from them and what it left on the
	ground, set through render3d/weather.lua and blended from one preset to
	the next.

	A preset may have these fields:
	- clouds: a list of cloud layers, see clouds.LAYER_DEFAULTS
	- rain, snow: mm/h, see weather.SetRain and weather.SetSnow
	- wetness, snow_depth: see weather.SetWetness and weather.SetSnowDepth
	- temperature, visibility, wind: see weather.SetTemperature and so on

	The fields in climate.DEFAULTS are set to their default when a preset
	leaves them out. temperature, visibility and wind are left as they are.

	Cloud layers are blended by name, so the same kind of layer should have
	the same name in every preset: low, mid, high and tower. A layer that is
	only on one side fades its coverage in or out. high is the flat one.
]]
climate.BLEND_TIME = 2
climate.DEFAULTS = {
	clouds = {},
	rain = 0,
	snow = 0,
	wetness = 0,
	snow_depth = 0,
}
climate.presets = {
	clear = {},
	-- small fair weather cumulus
	fair = {
		clouds = {
			{
				name = "low",
				bottom = 1300,
				thickness = 900,
				coverage = 0.3,
				density = 0.06,
				type = 1,
				shape_scale = 3500,
				detail_scale = 250,
				base_variation = 150,
			},
		},
	},
	-- partly cloudy: taller cumulus and a veil of cirrus
	cumulus = {
		clouds = {
			{
				name = "low",
				bottom = 1400,
				thickness = 2000,
				coverage = 0.42,
				density = 0.07,
				type = 1,
				detail_scale = 250,
				base_variation = 200,
			},
			{
				name = "high",
				bottom = 9000,
				thickness = 400,
				coverage = 0.35,
				density = 0.25,
				flat = true,
				weather_scale = 30000,
				shape_scale = 6000,
				wind_scale = 6,
			},
		},
	},
	-- towering cumulus, the weather before a storm
	congestus = {
		clouds = {
			{
				name = "low",
				bottom = 1200,
				thickness = 4500,
				coverage = 0.5,
				density = 0.08,
				type = 1,
				erosion = 0.3,
				shape_scale = 7000,
				detail_scale = 300,
				weather_scale = 50000,
				base_variation = 250,
			},
		},
	},
	stratocumulus = {
		clouds = {
			{
				name = "low",
				bottom = 900,
				thickness = 700,
				coverage = 0.72,
				density = 0.045,
				type = 0.5,
				shape_scale = 2500,
				detail_scale = 250,
				variation = 0.35,
				base_variation = 60,
			},
		},
	},
	-- a mackerel sky of small cloudlets in the middle troposphere
	altocumulus = {
		clouds = {
			{
				name = "mid",
				bottom = 4200,
				thickness = 500,
				coverage = 0.55,
				density = 0.04,
				type = 0.6,
				shape_scale = 1400,
				detail_scale = 150,
				erosion = 0.5,
				wind_scale = 4,
			},
			{
				name = "high",
				bottom = 9500,
				thickness = 400,
				coverage = 0.3,
				density = 0.2,
				flat = true,
				wind_scale = 6,
			},
		},
	},
	-- a grey sheet the sun shows through as through frosted glass
	altostratus = {
		clouds = {
			{
				name = "mid",
				bottom = 3500,
				thickness = 1500,
				coverage = 0.97,
				density = 0.004,
				type = 0,
				shape_scale = 8000,
				variation = 0.25,
				wind_scale = 4,
			},
		},
	},
	-- low grey overcast
	overcast = {
		clouds = {
			{
				name = "low",
				bottom = 600,
				thickness = 900,
				coverage = 1,
				density = 0.03,
				type = 0.15,
				shape_scale = 4000,
				detail_scale = 300,
				variation = 0.3,
			},
		},
	},
	-- nimbostratus: thick and dark, the rain falls from it
	rain = {
		clouds = {
			{
				name = "low",
				bottom = 500,
				thickness = 3000,
				coverage = 1,
				density = 0.05,
				type = 0.2,
				shape_scale = 6000,
				erosion = 0.5,
				variation = 0.3,
			},
		},
		rain = 4,
		wetness = 1,
	},
	-- cumulonimbus towers with anvils over ragged low cloud
	storm = {
		clouds = {
			{
				name = "low",
				bottom = 700,
				thickness = 700,
				coverage = 0.6,
				density = 0.05,
				type = 0.4,
				shape_scale = 2500,
				erosion = 0.6,
				wind_scale = 3,
			},
			{
				name = "tower",
				bottom = 1000,
				thickness = 10000,
				coverage = 0.45,
				density = 0.1,
				type = 1,
				anvil = 1,
				shape_scale = 6000,
				detail_scale = 400,
				weather_scale = 60000,
				erosion = 0.5,
				variation = 0.8,
				wind_scale = 1.5,
				base_variation = 200,
			},
		},
		rain = 20,
		wetness = 1,
	},
	-- nimbostratus below freezing
	snow = {
		clouds = {
			{
				name = "low",
				bottom = 500,
				thickness = 2000,
				coverage = 1,
				density = 0.04,
				type = 0.2,
				shape_scale = 6000,
				erosion = 0.5,
				variation = 0.3,
			},
		},
		snow = 1,
		snow_depth = 0.1,
		temperature = -5,
	},
	cirrus = {
		clouds = {
			{
				name = "high",
				bottom = 9000,
				thickness = 400,
				coverage = 0.6,
				density = 0.5,
				flat = true,
				weather_scale = 30000,
				shape_scale = 6000,
				wind_scale = 6,
			},
		},
	},
	-- a milky veil over the whole sky, the sun still casts soft shadows
	cirrostratus = {
		clouds = {
			{
				name = "high",
				bottom = 8500,
				thickness = 400,
				coverage = 1,
				density = 0.2,
				flat = true,
				weather_scale = 40000,
				shape_scale = 8000,
				variation = 0.15,
				wind_scale = 6,
			},
		},
	},
	-- cumulus under altocumulus under cirrus
	mixed = {
		clouds = {
			{
				name = "low",
				bottom = 1400,
				thickness = 1500,
				coverage = 0.35,
				density = 0.07,
				type = 1,
				base_variation = 150,
			},
			{
				name = "mid",
				bottom = 4500,
				thickness = 500,
				coverage = 0.4,
				density = 0.035,
				type = 0.6,
				shape_scale = 1600,
				detail_scale = 150,
				wind_scale = 4,
			},
			{
				name = "high",
				bottom = 9500,
				thickness = 400,
				coverage = 0.45,
				density = 0.25,
				flat = true,
				wind_scale = 6,
			},
		},
	},
	-- cumulus torn and curled by wind shear, under swirling altocumulus
	windy = {
		clouds = {
			{
				name = "low",
				bottom = 1300,
				thickness = 1400,
				coverage = 0.4,
				density = 0.06,
				type = 0.8,
				erosion = 0.5,
				swirl = 0.5,
				detail_scale = 250,
				base_variation = 150,
				wind_scale = 4,
			},
			{
				name = "mid",
				bottom = 4800,
				thickness = 500,
				coverage = 0.4,
				density = 0.035,
				type = 0.6,
				shape_scale = 2000,
				detail_scale = 150,
				swirl = 0.8,
				wind_scale = 6,
			},
		},
	},
}
climate.preset = nil
climate.from = nil
climate.to = nil
climate.blend_time = 0
climate.blend_elapsed = 0

-- 0 is a clear sky and 1 an overcast that hides the sun. in between, fair weather cumulus that grow
-- and spread into stratocumulus
function climate.GetCoverPreset(cover)
	if cover <= 0 then return {} end

	local spread = math.smoothstep(0.5, 1, cover)
	return {
		clouds = {
			{
				name = "low",
				bottom = math.lerp(spread, 1400, 700),
				thickness = math.lerp(cover, 900, 1400),
				coverage = cover,
				density = math.lerp(spread, 0.07, 0.035),
				type = math.lerp(spread, 1, 0.2),
				shape_scale = math.lerp(spread, 4000, 3500),
				variation = math.lerp(spread, 0.5, 0.3),
				base_variation = math.lerp(spread, 150, 50),
			},
		},
	}
end

-- every layer with all of its fields, and a name to match it by
local function fill_layers(list)
	local out = {}

	for i, params in ipairs(list) do
		local layer = {}

		for k, v in pairs(clouds.LAYER_DEFAULTS) do
			layer[k] = v
		end

		for k, v in pairs(params) do
			if clouds.LAYER_DEFAULTS[k] == nil then
				error("unknown cloud layer field " .. tostring(k), 4)
			end

			layer[k] = v
		end

		layer.name = layer.name or "#" .. i
		out[i] = layer
	end

	return out
end

local function get_state()
	local layers = {}

	for i, layer in ipairs(weather.GetCloudLayers()) do
		layers[i] = {}

		for k in pairs(clouds.LAYER_DEFAULTS) do
			layers[i][k] = layer[k]
		end
	end

	return {
		clouds = fill_layers(layers),
		rain = weather.GetRain(),
		snow = weather.GetSnow(),
		wetness = weather.GetWetness(),
		snow_depth = weather.GetSnowDepth(),
		temperature = weather.GetTemperature(),
		visibility = weather.GetVisibility(),
		wind = weather.GetWind():Copy(),
	}
end

local function resolve(preset, current)
	if type(preset) == "string" then
		preset = climate.presets[preset] or error("unknown climate preset " .. preset, 3)
	end

	local state = {}

	for k, v in pairs(preset) do
		if current[k] == nil then error("unknown climate field " .. tostring(k), 3) end
	end

	for k, v in pairs(current) do
		if preset[k] ~= nil then
			state[k] = preset[k]
		elseif climate.DEFAULTS[k] ~= nil then
			state[k] = climate.DEFAULTS[k]
		else
			state[k] = v
		end
	end

	state.clouds = fill_layers(state.clouds)
	return state
end

local function blend_layers(a, b, t)
	local out = {}
	local matched = {}

	for _, from in ipairs(a) do
		matched[from.name] = from
	end

	for _, to in ipairs(b) do
		local from = matched[to.name]
		local layer = table.copy(to)

		if from then
			matched[to.name] = nil

			if from.flat ~= to.flat then
				error("cloud layer " .. to.name .. " is flat on only one side of the blend", 3)
			end

			for k, v in pairs(to) do
				if type(v) == "number" then layer[k] = math.lerp(t, from[k], v) end
			end
		else
			layer.coverage = layer.coverage * t
		end

		if layer.coverage > 0 then list.insert(out, layer) end
	end

	for _, from in ipairs(a) do
		if matched[from.name] and t < 1 then
			local layer = table.copy(from)
			layer.coverage = layer.coverage * (1 - t)

			if layer.coverage > 0 then list.insert(out, layer) end
		end
	end

	return out
end

local function apply(a, b, t)
	weather.SetRain(math.lerp(t, a.rain, b.rain))
	weather.SetSnow(math.lerp(t, a.snow, b.snow))
	weather.SetWetness(math.lerp(t, a.wetness, b.wetness))
	weather.SetSnowDepth(math.lerp(t, a.snow_depth, b.snow_depth))
	weather.SetTemperature(math.lerp(t, a.temperature, b.temperature))
	-- the fog's extinction goes as one over the visibility
	weather.SetVisibility(1 / math.lerp(t, 1 / a.visibility, 1 / b.visibility))
	weather.SetWind(a.wind:GetLerped(t, b.wind))
	weather.SetCloudLayers(blend_layers(a.clouds, b.clouds, t))
end

local function update(dt)
	climate.blend_elapsed = climate.blend_elapsed + dt
	local t = climate.blend_time > 0 and
		math.min(climate.blend_elapsed / climate.blend_time, 1) or
		1
	apply(climate.from, climate.to, math.smoothstep(0, 1, t))

	if t >= 1 then
		climate.from = nil
		climate.to = nil
		event.RemoveListener("Update", "climate")
	end
end

-- a name from climate.presets or a preset table, blended into from the weather as it is now over
-- seconds (climate.BLEND_TIME when nil, 0 sets it at once)
function climate.SetPreset(preset, seconds)
	local current = get_state()
	climate.preset = preset
	climate.from = current
	climate.to = resolve(preset, current)
	climate.blend_time = seconds or climate.BLEND_TIME
	climate.blend_elapsed = 0

	if climate.blend_time <= 0 then
		update(0)
	else
		event.AddListener("Update", "climate", update)
	end
end

-- the name or table last given to SetPreset, the weather may have been changed since
function climate.GetPreset()
	return climate.preset
end

function climate.IsBlending()
	return climate.from ~= nil
end

-- sets the weather t of the way from preset a to preset b at once, stopping a blend
function climate.Blend(a, b, t)
	local current = get_state()
	climate.preset = nil
	climate.from = nil
	climate.to = nil
	event.RemoveListener("Update", "climate")
	apply(resolve(a, current), resolve(b, current), t)
end

commands.Add("climate=string", function(name)
	climate.SetPreset(name)
end)

commands.Add("cloud_cover=number", function(cover)
	climate.SetPreset(climate.GetCoverPreset(cover))
end)

return climate
