local event = import("goluwa/event.lua")
local input = import("goluwa/input.lua")
local objects = import("goluwa/objects/objects.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local PropertyEditor = import("goluwa/render2d/ui/widgets/property_editor.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local weather = import("goluwa/render3d/weather.lua")
local live_weather = import("lua/live_weather.lua")
local climate = import("goluwa/render3d/climate.lua")
local clouds = import("goluwa/render3d/clouds.lua")
local WIDTH = 460
local panel = NULL
local property_editor
local shown = false
local nodes = {}
local layer_signature = ""
local wind_direction = 0

-- editing by hand takes over from a preset that is still blending in
local function number_node(key, text, min, max, precision, get, set, help)
	local node = {
		Key = key,
		Text = text,
		Description = help or key,
		Type = "number",
		Min = min,
		Max = max,
		ShowSlider = true,
		Precision = precision,
		Value = get(),
		GetValue = get,
	}

	function node.OnChange(_, value)
		climate.Stop()
		set(value)
		node.Value = get()
	end

	nodes[#nodes + 1] = node
	return node
end

local function aerosol_getter(field)
	return function()
		return weather.GetAerosol()[field]
	end
end

local function aerosol_setter(field)
	return function(value)
		local aerosol = weather.GetAerosol()
		aerosol[field] = value
		weather.SetAerosol(aerosol)
	end
end

local function get_wind_direction()
	local wind = weather.GetWind()

	if wind.x * wind.x + wind.z * wind.z > 1e-4 then
		wind_direction = math.deg(math.atan2(wind.z, wind.x)) % 360
	end

	return wind_direction
end

local function get_wind_speed()
	local wind = weather.GetWind()
	return math.sqrt(wind.x * wind.x + wind.z * wind.z)
end

local function set_wind(direction, speed)
	local angle = math.rad(direction)
	weather.SetWind(Vec3(math.cos(angle) * speed, weather.GetWind().y, math.sin(angle) * speed))
end

local LAYER_FIELDS = {
	{"coverage", 0, 1, 3},
	{"density", 0, 0.6, 3},
	{"bottom", 0, 15000, 0},
	{"thickness", 50, 8000, 0},
	{"type", 0, 1, 3},
	{"erosion", 0, 1, 3},
	{"anvil", 0, 1, 3},
	{"variation", 0, 1, 3},
	{"base_variation", 0, 500, 0},
	{"swirl", 0, 2, 3},
	{"evolution", 0, 2, 3},
	{"wind_scale", 0, 10, 2},
	{"weather_scale", 5000, 100000, 0},
	{"shape_scale", 500, 20000, 0},
	{"detail_scale", 50, 1000, 0},
}

-- layers are addressed by name because setting layers sorts them by altitude
local function copy_layers()
	local list = {}

	for i, layer in ipairs(weather.GetCloudLayers()) do
		local params = {}

		for k in pairs(clouds.LAYER_DEFAULTS) do
			params[k] = layer[k]
		end

		params.name = layer.name or "layer " .. i
		list[i] = params
	end

	return list
end

local function find_layer(name)
	for _, layer in ipairs(weather.GetCloudLayers()) do
		if layer.name == name then return layer end
	end
end

local function set_layer_field(name, field, value)
	local list = copy_layers()

	for _, params in ipairs(list) do
		if params.name == name then params[field] = value end
	end

	weather.SetCloudLayers(list)
end

local function get_layer_names()
	local names = {}

	for i, layer in ipairs(weather.GetCloudLayers()) do
		names[i] = layer.name or "layer " .. i
	end

	table.sort(names)
	return names
end

local function get_signature()
	return table.concat(get_layer_names(), "\0")
end

local function build_layer_group(name, ui)
	local children = {}

	for _, field in ipairs(LAYER_FIELDS) do
		local key = field[1]
		children[#children + 1] = number_node(
			"clouds/" .. name .. "/" .. key,
			key,
			field[2],
			field[3],
			field[4],
			function()
				local layer = find_layer(name)
				return layer and layer[key] or 0
			end,
			function(value)
				set_layer_field(name, key, value)
			end
		)
	end

	local flat = {
		Key = "clouds/" .. name .. "/flat",
		Text = "flat",
		Description = "a flat sheet instead of a volume",
		Type = "boolean",
		Value = find_layer(name).flat,
		GetValue = function()
			return find_layer(name).flat
		end,
		OnChange = function(node, value)
			climate.Stop()
			set_layer_field(name, "flat", value)
			node.Value = find_layer(name).flat
		end,
	}
	nodes[#nodes + 1] = flat
	children[#children + 1] = flat
	children[#children + 1] = {
		Type = "action",
		Key = "clouds/" .. name .. "/remove",
		Text = "remove layer",
		ButtonText = "Remove",
		OnAction = function()
			climate.Stop()
			local list = {}

			for _, params in ipairs(copy_layers()) do
				if params.name ~= name then list[#list + 1] = params end
			end

			weather.SetCloudLayers(list)
		end,
	}
	return {
		Key = "clouds/" .. name,
		Text = name,
		Tab = "Clouds",
		Children = children,
	}
end

local function build_items()
	nodes = {}
	local preset_options = {}

	for name in pairs(climate.presets) do
		preset_options[#preset_options + 1] = name
	end

	table.sort(preset_options)

	for i, name in ipairs(preset_options) do
		preset_options[i] = {Text = name, Value = name}
	end

	local function get_preset()
		local preset = climate.GetPreset()
		return type(preset) == "string" and preset or nil
	end

	local preset = {
		Key = "weather/preset",
		Text = "preset",
		Description = "blend the whole weather into a climate preset",
		Type = "enum",
		Options = preset_options,
		Value = get_preset(),
		GetValue = get_preset,
		OnChange = function(_, value)
			climate.SetPreset(value)
		end,
	}
	nodes[#nodes + 1] = preset
	local items = {
		{
			Key = "weather/presets",
			Text = "Preset",
			Tab = "Preset",
			Children = {
				preset,
				{
					Type = "action",
					Key = "weather/live",
					Text = "live weather",
					Description = "fetch the current weather at the location and blend into it",
					ButtonText = "Fetch",
					OnAction = function()
						live_weather.Apply(function(applied, err)
							if applied then
								llog(
									"live weather: %.1f C, rain %.1f mm/h, visibility %d m, %d cloud layers, wind %.1f m/s",
									applied.temperature,
									applied.rain,
									applied.aerosol_visibility,
									#applied.clouds,
									applied.wind:GetLength()
								)
							else
								llog("live weather failed: %s", err)
							end
						end)
					end,
				},
			},
		},
		{
			Key = "weather/time",
			Text = "Time and place",
			Tab = "Sky",
			Children = {
				number_node("weather/hours", "time of day", 0, 24, 2, weather.GetSolarHours, weather.SetSolarHours, "local solar hours"),
				number_node("weather/day", "day of year", 1, 366, 0, weather.GetDayOfYear, weather.SetDayOfYear),
				number_node("weather/latitude", "latitude", -90, 90, 2, function()
					return (weather.GetLocation())
				end, function(value)
					weather.SetLocation(value, select(2, weather.GetLocation()))
				end),
				number_node("weather/longitude", "longitude", -180, 180, 2, function()
					return select(2, weather.GetLocation())
				end, function(value)
					weather.SetLocation((weather.GetLocation()), value)
				end),
				number_node("weather/time_scale", "time scale", 0, 3600, 0, weather.GetTimeScale, weather.SetTimeScale, "game seconds per second"),
			},
		},
		{
			Key = "weather/sky",
			Text = "Sky",
			Tab = "Sky",
			Children = {
				number_node("weather/moon_scale", "moon scale", 0, 10, 2, weather.GetMoonScale, weather.SetMoonScale),
			},
		},
		{
			Key = "weather/air",
			Text = "Air",
			Tab = "Air",
			Children = {
				number_node("weather/temperature", "temperature", -40, 50, 1, weather.GetTemperature, weather.SetTemperature, "celsius"),
				number_node("weather/aerosol", "aerosol visibility", 1.5, 5.5, 2, function()
					return math.log10(weather.GetAerosolVisibility())
				end, function(value)
					weather.SetAerosolVisibility(10 ^ value)
				end, "log10 of meters"),
				number_node("weather/ground_fog", "ground fog visibility", 1.5, 5.5, 2, function()
					return math.log10(weather.GetGroundFogVisibility())
				end, function(value)
					weather.SetGroundFogVisibility(10 ^ value)
				end, "log10 of meters"),
			},
		},
		{
			Key = "weather/aerosol_shape",
			Text = "Aerosol particles",
			Tab = "Air",
			Children = {
				number_node(
					"weather/aerosol_angstrom",
					"angstrom exponent",
					0,
					3,
					2,
					aerosol_getter("angstrom"),
					aerosol_setter("angstrom"),
					"how fast the extinction falls with wavelength, larger is smaller particles and a bluer haze that reddens the sun"
				),
				number_node(
					"weather/aerosol_albedo",
					"single scattering albedo",
					0.5,
					1,
					3,
					aerosol_getter("albedo"),
					aerosol_setter("albedo"),
					"1 scatters everything, lower absorbs, smoke and soot are around 0.85"
				),
				number_node(
					"weather/aerosol_g",
					"asymmetry",
					0,
					0.95,
					2,
					aerosol_getter("g"),
					aerosol_setter("g"),
					"how forward the particles scatter, the glow around the sun"
				),
				number_node(
					"weather/aerosol_height",
					"layer height",
					0.1,
					4,
					2,
					aerosol_getter("scale_height"),
					aerosol_setter("scale_height"),
					"scale height of the aerosol in km"
				),
			},
		},
		{
			Key = "weather/wind",
			Text = "Wind",
			Tab = "Air",
			Children = {
				number_node("weather/wind_direction", "direction", 0, 360, 0, get_wind_direction, function(value)
					wind_direction = value
					set_wind(value, get_wind_speed())
				end, "degrees, 0 blows towards +x, 90 towards +z"),
				number_node("weather/wind_speed", "speed", 0, 40, 1, get_wind_speed, function(value)
					set_wind(wind_direction, value)
				end, "meters per second"),
			},
		},
		{
			Key = "weather/precipitation",
			Text = "Precipitation",
			Tab = "Ground",
			Children = {
				number_node("weather/rain", "rain", 0, 100, 1, weather.GetRain, weather.SetRain, "mm per hour"),
				number_node("weather/snow", "snow", 0, 30, 1, weather.GetSnow, weather.SetSnow, "mm per hour"),
			},
		},
		{
			Key = "weather/surface",
			Text = "Surfaces",
			Tab = "Ground",
			Children = {
				number_node("weather/wetness", "wetness", 0, 1, 3, weather.GetWetness, weather.SetWetness),
				number_node("weather/snow_depth", "snow depth", 0, 2, 3, weather.GetSnowDepth, weather.SetSnowDepth, "meters"),
			},
		},
	}
	layer_signature = get_signature()
	local names = get_layer_names()

	for _, name in ipairs(names) do
		items[#items + 1] = build_layer_group(name)
	end

	items[#items + 1] = {
		Key = "clouds/layers",
		Text = "Layers",
		Tab = "Clouds",
		Children = {
			{
				Type = "action",
				Key = "clouds/add",
				Text = "add layer",
				ButtonText = "Add",
				OnAction = function()
					if #names >= clouds.MAX_LAYERS then return end

					climate.Stop()
					local list = copy_layers()
					local n = #list + 1

					while find_layer("layer " .. n) do
						n = n + 1
					end

					list[#list + 1] = {name = "layer " .. n}
					weather.SetCloudLayers(list)
				end,
			},
		},
	}
	return items
end

local function name_layers()
	for _, layer in ipairs(weather.GetCloudLayers()) do
		if not layer.name then
			weather.SetCloudLayers(copy_layers())

			return
		end
	end
end

local function sync()
	name_layers()

	if get_signature() ~= layer_signature then
		property_editor:SetItems(build_items())

		return
	end

	for _, node in ipairs(nodes) do
		local value = node.GetValue()

		if value ~= node.Value then property_editor:UpdateValueForKey(node.Key, value) end
	end
end

local function is_editing()
	if not panel:IsValid() then return false end

	local focused = objects.GetFocusedObject()

	while focused and focused:IsValid() do
		if focused == panel then return true end

		focused = focused:GetParent()
	end

	return false
end

local function show()
	local world = Panel.World

	if not panel:IsValid() then
		name_layers()
		panel = world:Ensure(
			Window{
				Key = "WeatherWindow",
				Title = "WEATHER",
				RequestMouse = true,
				Padding = "none",
				Closable = false,
				Minimizable = false,
				Maximizable = false,
				MinSize = Vec2(WIDTH, 200),
			}{
				ScrollablePanel{
					ScrollX = false,
					ScrollY = true,
					Padding = "M",
					layout = {GrowWidth = 1, GrowHeight = 1},
				}{
					PropertyEditor{
						Ref = function(self)
							property_editor = self
						end,
						Items = build_items(),
						layout = {GrowWidth = 1},
					},
				},
			}
		)
	end

	local size = world.transform:GetSize()
	panel.transform:SetSize(Vec2(WIDTH, size.y))
	panel.transform:SetPosition(Vec2(0, 0))
	panel.visual:SetVisible(true)
	shown = true
	sync()
end

event.AddListener("Update", "weather_panel", function()
	if shown and panel:IsValid() then sync() end
end)

input.Bind("q", "+show_weather", function()
	show()
end)

input.Bind("q", "-show_weather", function()
	if not panel:IsValid() or is_editing() then return end

	panel.visual:SetVisible(false)
	shown = false
end)
