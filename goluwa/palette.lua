local Color = import("goluwa/structs/color.lua")
local prototype = import("goluwa/prototype.lua")
local ColorPalette = prototype.CreateTemplate("color_palette")
local accent_names = {"red", "yellow", "blue", "green", "purple", "brown"}
local accent_hues = {
	red = 0 / 6,
	yellow = 1 / 6,
	green = 2 / 6,
	blue = 3.55 / 6,
	purple = 4.6 / 6,
	brown = 0.18 / 6,
}
local accent_modifiers = {
	brown = {saturation = 0.7, value = 0.55},
	yellow = {saturation = 0.9, value = 1},
	blue = {saturation = 1, value = 0.95},
	purple = {saturation = 0.95, value = 0.9},
}
local dark_names = {"black", "darkest", "darker", "dark"}
local light_names = {"light", "lighter", "lightest", "white"}
local base_shades = {
	"black",
	"darkest",
	"darker",
	"dark",
	"grey",
	"light",
	"lighter",
	"lightest",
	"white",
}
local base_token = "__base__"
local accent_shades = {
	"black",
	"darkest",
	"darker",
	"dark",
	"grey",
	"light",
	"lighter",
	"lightest",
	"white",
}
local contrast_suffixes_for_dark_surface = {
	"lightest",
	"lighter",
	"light",
	"white",
	"grey",
	base_token,
	"dark",
	"darker",
	"darkest",
	"black",
}
local contrast_suffixes_for_light_surface = {
	"darkest",
	"darker",
	"dark",
	"black",
	"grey",
	base_token,
	"light",
	"lighter",
	"lightest",
	"white",
}

local function copy_color(color)
	return Color.CType(color.r, color.g, color.b, color.a)
end

local function is_color_value(value)
	if value == nil then return false end

	if typex(value) == "color" then return true end

	return type(value) == "table" and value.r ~= nil and value.g ~= nil and value.b ~= nil
end

local function copy_value(value)
	if is_color_value(value) and value.Copy then return value:Copy() end

	return value
end

local function get_cache_key_part(value)
	if value == nil then return "" end

	if is_color_value(value) then
		return string.format("%.6f,%.6f,%.6f,%.6f", value.r, value.g, value.b, value.a or 1)
	end

	return tostring(value)
end

local function get_color_from_input(value)
	return Color.FromName(value)
end

local function get_canonical_distance(a, b)
	local diff = math.abs(a - b)
	return math.min(diff, 1 - diff)
end

local function get_closest_accent_name(name, colors)
	local found_name
	local found_distance

	for other_name, other_color in pairs(colors) do
		if other_color and accent_hues[other_name] then
			local distance = get_canonical_distance(accent_hues[name], accent_hues[other_name])

			if not found_distance or distance < found_distance then
				found_name = other_name
				found_distance = distance
			end
		end
	end

	return found_name
end

local function infer_accent_color(name, colors)
	local source_name = get_closest_accent_name(name, colors)
	local source = source_name and colors[source_name] or Color.FromHex("#808080")
	local _, saturation, value = source:GetHSV()
	local modifier = accent_modifiers[name] or {}
	local color = Color.FromHSV(
		accent_hues[name],
		math.clamp(saturation * (modifier.saturation or 1), 0, 1),
		math.clamp(value * (modifier.value or 1), 0, 1)
	)
	color.a = source.a
	return color
end

local function normalize_colors(colors)
	local normalized = {}

	for key, value in pairs(colors or {}) do
		local name = type(key) == "number" and accent_names[key] or key

		if name and accent_hues[name] then
			normalized[name] = get_color_from_input(value)
		end
	end

	if not next(normalized) then
		error("SetColors requires at least one accent color", 3)
	end

	for _, name in ipairs(accent_names) do
		if not normalized[name] then
			normalized[name] = infer_accent_color(name, normalized)
		end
	end

	return normalized
end

local function split_color_token(token)
	for _, shade in ipairs(accent_shades) do
		local suffix = "_" .. shade

		if token:sub(-#suffix) == suffix then
			return token:sub(1, #token - #suffix), shade
		end
	end

	return token, nil
end

local function scale_colors(colors)
	return function(t)
		if #colors == 0 then return Color.CType(0, 0, 0, 1) end

		if #colors == 1 then return colors[1]:Copy() end

		if t <= 0 then return colors[1]:Copy() end

		if t >= 1 then return colors[#colors]:Copy() end

		local scaled_t = t * (#colors - 1)
		local index = math.floor(scaled_t) + 1
		local fraction = scaled_t - index + 1
		return colors[index]:GetLerped(fraction, colors[index + 1])
	end
end

local function normalize_shades(shades_input)
	local input = {}

	if #shades_input > 0 then
		for i = 1, #shades_input do
			input[i] = Color.FromName(shades_input[i])
		end
	elseif shades_input.dark and shades_input.bright then
		input[1] = Color.FromName(shades_input.dark)
		input[2] = Color.FromName(shades_input.bright)
	else
		error("SetShades requires at least a dark and bright shade", 3)
	end

	if #input < 2 then
		error("SetShades requires at least a dark and bright shade", 3)
	end

	do
		local _, _, first_value = input[1]:GetHSV()
		local _, _, last_value = input[#input]:GetHSV()

		if first_value > last_value then
			local reversed = {}

			for i = #input, 1, -1 do
				reversed[#reversed + 1] = input[i]
			end

			input = reversed
		end
	end

	if #input == #base_shades then return input end

	local get_shade = scale_colors(input)
	local normalized = {}

	for i = 1, #base_shades do
		normalized[i] = get_shade((i - 1) / (#base_shades - 1))
	end

	return normalized
end

local function build_base_palette(shades_input, colors_input)
	local palette = {}
	local accent_colors = normalize_colors(colors_input)
	local shades = normalize_shades(shades_input)

	for key, value in pairs(accent_colors) do
		palette[key] = copy_color(value)
	end

	do
		local gen_shade = scale_colors(shades)

		for i, shade_name in ipairs(dark_names) do
			local idx = i - 1

			for color_name, color in pairs(accent_colors) do
				palette[color_name .. "_" .. shade_name] = color:Darken((4 - idx) / 1.25):Mix(gen_shade(math.lerp(idx / 4, 0.5, 0)), 0):SetAlpha(1)
			end
		end

		for i, shade_name in ipairs(light_names) do
			local idx = i - 1

			for color_name, color in pairs(accent_colors) do
				palette[color_name .. "_" .. shade_name] = color:Brighten(idx / 1.25):Desaturate(idx / 0.75):Mix(gen_shade(math.lerp(idx / 4, 1, 0.5)), 0):SetAlpha(1)
			end
		end

		for color_name, color in pairs(accent_colors) do
			palette[color_name .. "_grey"] = color:Mix(gen_shade(4 / 8), 0.35):SetAlpha(1)
		end

		for i, shade_name in ipairs(base_shades) do
			local idx = i - 1
			palette[shade_name] = gen_shade(idx / 8):SetAlpha(1)
		end
	end

	return palette
end

local function get_surface_value(color)
	local _, _, value = color:GetHSV()
	return value
end

local function get_contrast_suffixes(surface_color)
	if get_surface_value(surface_color) <= 0.5 then
		return contrast_suffixes_for_dark_surface
	end

	return contrast_suffixes_for_light_surface
end

local function find_contrast_variant(base_palette, token, surface_color)
	local family = split_color_token(token)

	for _, suffix in ipairs(get_contrast_suffixes(surface_color)) do
		local candidate = suffix == base_token and family or (family .. "_" .. suffix)

		if base_palette[candidate] then return base_palette[candidate] end
	end

	if base_palette[token] then return base_palette[token] end

	error("unable to resolve color token '" .. token .. "'", 3)
end

function ColorPalette.New()
	return ColorPalette:CreateObject{
		Shades = {},
		Colors = {},
		Map = {},
		base_palette = {},
		mapped_palette = {},
		cache = {},
	}
end

function ColorPalette:Copy()
	local copy = ColorPalette.New()
	copy:SetShades(self.Shades)
	copy:SetColors(self.Colors)
	copy:SetMap(self.Map)

	if self.AdjustmentOptions then
		copy.AdjustmentOptions = table.merge_many({}, self.AdjustmentOptions)
	end

	return copy
end

function ColorPalette:Invalidate()
	self.base_palette = {}
	self.mapped_palette = {}
	self.cache = {}
end

function ColorPalette:Rebuild()
	if not next(self.Shades) or not next(self.Colors) then
		self.base_palette = {}
		self.mapped_palette = {}
		self.cache = {}
		return self.base_palette
	end

	self.base_palette = build_base_palette(self.Shades, self.Colors)
	self.mapped_palette = {}
	self.cache = {}
	return self.base_palette
end

function ColorPalette:SetShades(shades)
	self.Shades = table.merge_many({}, shades or {})
	self:Invalidate()
	self:Rebuild()
	return self
end

function ColorPalette:SetColors(colors)
	self.Colors = table.merge_many({}, colors or {})
	self:Invalidate()
	self:Rebuild()
	return self
end

function ColorPalette:SetMap(map)
	self.Map = table.merge_many({}, map or {})
	self.mapped_palette = {}
	self.cache = {}
	return self
end

function ColorPalette:GetBaseMap()
	return self.base_palette
end

function ColorPalette:GetMap()
	return self.Map
end

function ColorPalette:GetMappedMap()
	if next(self.mapped_palette) then return self.mapped_palette end

	for key, value in pairs(self.Map) do
		if type(value) == "string" and self.base_palette[value] then
			self.mapped_palette[key] = self.base_palette[value]
		elseif is_color_value(value) then
			self.mapped_palette[key] = value
		end
	end

	return self.mapped_palette
end

function ColorPalette:GetBase(token)
	local color = self.base_palette[token]

	if color then return color end

	error("unknown base color token '" .. token .. "'", 2)
end

function ColorPalette:GetMapped(token)
	local color = self:GetMappedMap()[token]

	if color then return color end

	error("unknown mapped color token '" .. token .. "'", 2)
end

function ColorPalette:Get(token, surface)
	local cache_key = get_cache_key_part(token) .. "|" .. get_cache_key_part(surface)
	local cached = self.cache[cache_key]

	if cached then return cached end

	local mapped_token = self.Map[token] or token

	if type(mapped_token) ~= "string" and not is_color_value(mapped_token) then
		error("invalid mapped token for '" .. token .. "'", 2)
	end

	local color

	if surface then
		local mapped_surface = self.Map[surface] or surface
		local surface_color

		if type(mapped_surface) == "string" then
			surface_color = self.base_palette[mapped_surface]
		elseif is_color_value(mapped_surface) then
			surface_color = mapped_surface
		end

		if not surface_color then
			error("unknown surface token '" .. surface .. "'", 2)
		end

		local explicit_token

		if type(token) == "string" and type(surface) == "string" then
			explicit_token = self.Map[token .. "_on_" .. surface]
		end

		if explicit_token then
			if type(explicit_token) == "string" then
				color = self.base_palette[explicit_token]
			elseif is_color_value(explicit_token) then
				color = explicit_token
			end
		else
			local candidate

			if type(mapped_token) == "string" then
				candidate = find_contrast_variant(self.base_palette, mapped_token, surface_color)
			else
				candidate = mapped_token
			end

			color = candidate:GetAdjustedForBackground(surface_color, self.AdjustmentOptions)
		end
	else
		if type(mapped_token) == "string" then
			color = self.base_palette[mapped_token]
		else
			color = mapped_token
		end
	end

	if not color then error("unknown color token '" .. mapped_token .. "'", 2) end

	self.cache[cache_key] = copy_value(color)
	return color
end

function ColorPalette.Build(shades_input, colors_input, semantic_input, overrides)
	local palette = ColorPalette.New()
	palette:SetShades(shades_input)
	palette:SetColors(colors_input)

	if type(semantic_input) == "function" then
		semantic_input = semantic_input(palette:GetBaseMap())
	end

	palette:SetMap(table.merge_many(semantic_input or {}, overrides or {}))
	return palette:GetMappedMap(), palette:GetBaseMap()
end

ColorPalette:Register()
return ColorPalette
