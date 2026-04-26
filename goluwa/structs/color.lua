local structs = import("goluwa/structs/structs.lua")
local out = {}
local META = structs.Template("Color")
META.Args = {{"r", "g", "b", "a"}}
structs.AddAllOperators(META)

function META:SetAlpha(a)
	self.a = a
	return self
end

function META:Lighter(factor)
	factor = factor or .5
	factor = factor + 1
	return META.CType(self.r * factor, self.g * factor, self.b * factor, self.a)
end

function META:Darker(factor)
	return self:Lighter((1 - (factor or .5)) - 1)
end

function META:Get255()
	return META.CType(self.r * 255, self.g * 255, self.b * 255, self.a * 255)
end

function META:SetHue(h)
	local _h, s, l = self:GetHSV()
	_h = (_h + h) % 1
	local new = META.FromHSV(_h, s, l)
	self.r = new.r
	self.g = new.g
	self.b = new.b
	self.a = new.a
	return self
end

function META:SetComplementary()
	return self:SetHue(math.pi)
end

function META:GetNeighbors(angle)
	angle = angle or 30
	return self:SetHue(angle), self:SetHue(360 - angle)
end

function META:GetNeighbors()
	return self:GetNeighbors(120)
end

function META:GetSplitComplementary(angle)
	return self:GetNeighbors(180 - (angle or 30))
end

function META.Lerp(a, mult, b)
	a.r = (b.r - a.r) * mult + a.r
	a.g = (b.g - a.g) * mult + a.g
	a.b = (b.b - a.b) * mult + a.b
	a.a = (b.a - a.a) * mult + a.a
	return a
end

structs.AddGetFunc(META, "Lerp", "Lerped")

function META:SetSaturation(s)
	local h, _, l = self:GetHSV()
	local new = META.FromHSV(h, s, l)
	self.r = new.r
	self.g = new.g
	self.b = new.b
	self.a = new.a
	return self
end

function META:SetLightness(l)
	local h, s, _ = self:GetHSV()
	local new = META.FromHSV(h, s, l)
	self.r = new.r
	self.g = new.g
	self.b = new.b
	self.a = new.a
	return self
end

function META:GetTints(count)
	local tbl = {}

	for i = 1, count do
		local _, _, v = self:GetHSV()
		local copy = self:Copy()
		copy:SetLightness(v + (1 - v) / count * i)
		table.insert(tbl, copy)
	end

	return tbl
end

function META:GetShades(count)
	local tbl = {}

	for i = 1, count do
		local _, _, v = self:GetHSV()
		local copy = self:Copy()
		copy:SetLightness(v - (v) / count * i)
		table.insert(tbl, copy)
	end

	return tbl
end

function META:GetHex()
	return bit.bor(bit.lshift(self.r * 255, 16), bit.lshift(self.g * 255, 8), self.b * 255)
end

function META:SetTint(num)
	local _, _, v = self:GetHSV()
	self:SetLightness(v + (1 - v) * num)
	return self
end

function META:SetShade(num)
	local _, _, v = self:GetHSV()
	self:SetLightness(v - v * num)
	return self
end

function META:GetHSV()
	local r = self.r
	local g = self.g
	local b = self.b
	local h = 0
	local s = 0
	local v
	local min = math.min(r, g, b)
	local max = math.max(r, g, b)
	v = max
	local delta = max - min

	-- xxx: how do we deal with complete black?
	if min == 0 and max == 0 then
		-- we have complete darkness; make it cheap.
		return 0, 0, 0
	end

	if max == 0 then return 0, 0, v end

	s = delta / max -- rofl deltamax :|

	if delta == 0 then return 0, 0, v end

	if r == max then
		h = (g - b) / delta -- yellow/magenta
	elseif g == max then
		h = 2 + (b - r) / delta -- cyan/yellow
	else
		h = 4 + (r - g) / delta -- magenta/cyan
	end

	h = h / 6

	if h < 0 then h = h + 1 end

	return h, s, v
end

function META.FromBytes(r, g, b, a)
	r = r or 0
	g = g or 0
	b = b or 0
	a = a or 255
	return META.CType(r / 255, g / 255, b / 255, a / 255)
end

function META.FromHex(hex)
	local int = tonumber("0x" .. hex:sub(2))

	if int > 0xFFFFFF then
		local r = bit.rshift(bit.band(int, 0xFF000000), 24)
		local g = bit.rshift(bit.band(int, 0x00FF0000), 16)
		local b = bit.rshift(bit.band(int, 0x0000FF00), 8)
		local a = bit.band(int, 0x000000FF)
		return META.FromBytes(r, g, b, a)
	end

	local r = bit.rshift(bit.band(int, 0xFF0000), 16)
	local g = bit.rshift(bit.band(int, 0x00FF00), 8)
	local b = bit.band(int, 0x0000FF)
	local a = 255
	return META.FromBytes(r, g, b, a)
end

local names = {
	aliceblue = "#f0f8ff",
	antiquewhite = "#faebd7",
	aqua = "#00ffff",
	aquamarine = "#7fffd4",
	azure = "#f0ffff",
	beige = "#f5f5dc",
	bisque = "#ffe4c4",
	black = "#000000",
	blanchedalmond = "#ffebcd",
	blue = "#0000ff",
	blueviolet = "#8a2be2",
	brown = "#a52a2a",
	burlywood = "#deb887",
	cadetblue = "#5f9ea0",
	chartreuse = "#7fff00",
	chocolate = "#d2691e",
	coral = "#ff7f50",
	cornflowerblue = "#6495ed",
	cornsilk = "#fff8dc",
	crimson = "#dc143c",
	cyan = "#00ffff",
	darkblue = "#00008b",
	darkcyan = "#008b8b",
	darkgoldenrod = "#b8860b",
	darkgray = "#a9a9a9",
	darkgreen = "#006400",
	darkgrey = "#a9a9a9",
	darkkhaki = "#bdb76b",
	darkmagenta = "#8b008b",
	darkolivegreen = "#556b2f",
	darkorange = "#ff8c00",
	darkorchid = "#9932cc",
	darkred = "#8b0000",
	darksalmon = "#e9967a",
	darkseagreen = "#8fbc8f",
	darkslateblue = "#483d8b",
	darkslategray = "#2f4f4f",
	darkslategrey = "#2f4f4f",
	darkturquoise = "#00ced1",
	darkviolet = "#9400d3",
	deeppink = "#ff1493",
	deepskyblue = "#00bfff",
	dimgray = "#696969",
	dimgrey = "#696969",
	dodgerblue = "#1e90ff",
	firebrick = "#b22222",
	floralwhite = "#fffaf0",
	forestgreen = "#228b22",
	fuchsia = "#ff00ff",
	gainsboro = "#dcdcdc",
	ghostwhite = "#f8f8ff",
	gold = "#ffd700",
	goldenrod = "#daa520",
	gray = "#808080",
	green = "#008000",
	greenyellow = "#adff2f",
	grey = "#808080",
	honeydew = "#f0fff0",
	hotpink = "#ff69b4",
	indianred = "#cd5c5c",
	indigo = "#4b0082",
	ivory = "#fffff0",
	khaki = "#f0e68c",
	lavender = "#e6e6fa",
	lavenderblush = "#fff0f5",
	lawngreen = "#7cfc00",
	lemonchiffon = "#fffacd",
	lightblue = "#add8e6",
	lightcoral = "#f08080",
	lightcyan = "#e0ffff",
	lightgoldenrodyellow = "#fafad2",
	lightgray = "#d3d3d3",
	lightgreen = "#90ee90",
	lightgrey = "#d3d3d3",
	lightpink = "#ffb6c1",
	lightsalmon = "#ffa07a",
	lightseagreen = "#20b2aa",
	lightskyblue = "#87cefa",
	lightslategray = "#778899",
	lightslategrey = "#778899",
	lightsteelblue = "#b0c4de",
	lightyellow = "#ffffe0",
	lime = "#00ff00",
	limegreen = "#32cd32",
	linen = "#faf0e6",
	magenta = "#ff00ff",
	maroon = "#800000",
	mediumaquamarine = "#66cdaa",
	mediumblue = "#0000cd",
	mediumorchid = "#ba55d3",
	mediumpurple = "#9370db",
	mediumseagreen = "#3cb371",
	mediumslateblue = "#7b68ee",
	mediumspringgreen = "#00fa9a",
	mediumturquoise = "#48d1cc",
	mediumvioletred = "#c71585",
	midnightblue = "#191970",
	mintcream = "#f5fffa",
	mistyrose = "#ffe4e1",
	moccasin = "#ffe4b5",
	navajowhite = "#ffdead",
	navy = "#000080",
	oldlace = "#fdf5e6",
	olive = "#808000",
	olivedrab = "#6b8e23",
	orange = "#ffa500",
	orangered = "#ff4500",
	orchid = "#da70d6",
	palegoldenrod = "#eee8aa",
	palegreen = "#98fb98",
	paleturquoise = "#afeeee",
	palevioletred = "#db7093",
	papayawhip = "#ffefd5",
	peachpuff = "#ffdab9",
	peru = "#cd853f",
	pink = "#ffc0cb",
	plum = "#dda0dd",
	powderblue = "#b0e0e6",
	purple = "#800080",
	rebeccapurple = "#663399",
	red = "#ff0000",
	rosybrown = "#bc8f8f",
	royalblue = "#4169e1",
	saddlebrown = "#8b4513",
	salmon = "#fa8072",
	sandybrown = "#f4a460",
	seagreen = "#2e8b57",
	seashell = "#fff5ee",
	sienna = "#a0522d",
	silver = "#c0c0c0",
	skyblue = "#87ceeb",
	slateblue = "#6a5acd",
	slategray = "#708090",
	slategrey = "#708090",
	snow = "#fffafa",
	springgreen = "#00ff7f",
	steelblue = "#4682b4",
	tan = "#d2b48c",
	teal = "#008080",
	thistle = "#d8bfd8",
	tomato = "#ff6347",
	turquoise = "#40e0d0",
	violet = "#ee82ee",
	wheat = "#f5deb3",
	white = "#ffffff",
	whitesmoke = "#f5f5f5",
	yellow = "#ffff00",
	yellowgreen = "#9acd32",
}

function META.FromName(name)
	if type(name) == "cdata" then return name end

	if name:starts_with("#") then return META.FromHex(name) end

	return META.FromHex(names[name:lower()] or names.black)
end

local Vec3 = import("goluwa/structs/vec3.lua")

function META.ToName(color)
	local vec3color = Vec3(color.r, color.g, color.b)
	local found = {}

	for name, hex in pairs(names) do
		local c = META.FromHex(hex)
		table.insert(found, {distance = Vec3(c.r, c.g, c.b):Distance(vec3color), name = name})
	end

	table.sort(found, function(a, b)
		return a.distance < b.distance
	end)

	return found[1].name
end

-- http://code.google.com/p/sm-ssc/source/browse/Themes/_fallback/Scripts/02+Colors.lua?spec=svnca631130221f6ed8b9065685186fb696660bc79a&name=ca63113022&r=ca631130221f6ed8b9065685186fb696660bc79a
function META.FromHSV(h, s, v)
	h = (h % 1 * 360) / 60
	s = s or 1
	v = v or 1
	a = a or 1

	if s == 0 then return META.CType(v, v, v) end

	local i = math.floor(h)
	local f = h - i
	local p = v * (1 - s)
	local q = v * (1 - s * f)
	local t = v * (1 - s * (1 - f))

	if i == 0 then
		return META.CType(v, t, p)
	elseif i == 1 then
		return META.CType(q, v, p)
	elseif i == 2 then
		return META.CType(p, v, t)
	elseif i == 3 then
		return META.CType(p, q, v)
	elseif i == 4 then
		return META.CType(t, p, v)
	end

	return META.CType(v, p, q, 1)
end

function META:ToHex()
	return (
		"#%02x%02x%02x"
	):format(
		math.clamp(math.round(self.r * 255), 0, 255),
		math.clamp(math.round(self.g * 255), 0, 255),
		math.clamp(math.round(self.b * 255), 0, 255)
	)
end

local function to_linear_channel(channel)
	if channel <= 0.04045 then return channel / 12.92 end

	return ((channel + 0.055) / 1.055) ^ 2.4
end

local function hue_distance(a, b)
	local diff = math.abs(a - b)
	return math.min(diff, 1 - diff)
end

function META:GetRelativeLuminance()
	local r = to_linear_channel(self.r)
	local g = to_linear_channel(self.g)
	local b = to_linear_channel(self.b)
	return 0.2126 * r + 0.7152 * g + 0.0722 * b
end

function META:GetContrastRatio(other)
	local a = self:GetRelativeLuminance()
	local b = other:GetRelativeLuminance()
	local light = math.max(a, b)
	local dark = math.min(a, b)
	return (light + 0.05) / (dark + 0.05)
end

function META:GetAdjustedForBackground(background, options)
	options = options or {}
	local target_contrast = options.target_contrast or 4.5
	local max_hue_shift = options.max_hue_shift or 0.04
	local sat_floor = options.saturation_floor or 0
	local sat_steps = options.saturation_steps or 6
	local value_steps = options.value_steps or 24
	local hue_steps = options.hue_steps or 4
	local base_h, base_s, base_v = self:GetHSV()
	local white = META.CType(1, 1, 1, self.a)
	local black = META.CType(0, 0, 0, self.a)
	local prefer_lighter = white:GetContrastRatio(background) >= black:GetContrastRatio(background)
	local best_candidate = self
	local best_score = math.huge
	local best_ratio = self:GetContrastRatio(background)

	local function consider(candidate_h, candidate_s, candidate_v)
		local candidate = META.FromHSV(candidate_h, candidate_s, candidate_v):SetAlpha(self.a)
		local ratio = candidate:GetContrastRatio(background)
		local score = 0

		if ratio < target_contrast then
			score = score + (target_contrast - ratio) * 100
		else
			score = score - math.min(ratio - target_contrast, 3)
		end

		score = score + math.abs(candidate_v - base_v) * 8
		score = score + math.abs(candidate_s - base_s) * 4
		score = score + hue_distance(candidate_h, base_h) * 12

		if score < best_score or (score == best_score and ratio > best_ratio) then
			best_candidate = candidate
			best_score = score
			best_ratio = ratio
		end
	end

	for hue_index = -hue_steps, hue_steps do
		local hue_shift = (hue_index / math.max(hue_steps, 1)) * max_hue_shift
		local candidate_h = (base_h + hue_shift) % 1

		for sat_index = 0, sat_steps do
			local t = sat_steps == 0 and 0 or sat_index / sat_steps
			local candidate_s = math.lerp(t, base_s, sat_floor)

			for value_index = 0, value_steps do
				local t_value = value_steps == 0 and 0 or value_index / value_steps
				local candidate_v

				if prefer_lighter then
					candidate_v = math.lerp(t_value, math.max(base_v, 0), 1)
				else
					candidate_v = math.lerp(t_value, math.min(base_v, 1), 0)
				end

				consider(candidate_h, candidate_s, candidate_v)
			end
		end
	end

	return best_candidate
end

function META:Mix(other, ratio)
	return self:GetLerped(ratio or 0.5, other)
end

function META:Darken(amount)
	local h, s, v = self:GetHSV()
	return META.FromHSV(h, s, math.clamp(v - (amount or 1) * 0.1, 0, 1))
end

function META:Brighten(amount)
	local h, s, v = self:GetHSV()
	return META.FromHSV(h, s, math.clamp(v + (amount or 1) * 0.1, 0, 1))
end

function META:Desaturate(amount)
	local h, s, v = self:GetHSV()
	return META.FromHSV(h, math.clamp(s - (amount or 1) * 0.1, 0, 1), v)
end

local function scale_colors(colors)
	return function(t)
		if #colors == 0 then return META.CType(0, 0, 0, 1) end

		if #colors == 1 then return colors[1]:Copy() end

		if t <= 0 then return colors[1]:Copy() end

		if t >= 1 then return colors[#colors]:Copy() end

		local scaled_t = t * (#colors - 1)
		local index = math.floor(scaled_t) + 1
		local fraction = scaled_t - index + 1
		return colors[index]:GetLerped(fraction, colors[index + 1])
	end
end

function META.BuildPalette(shades_input, colors_input)
	local ColorPalette = import("goluwa/palette.lua")
	local palette = ColorPalette.New()
	palette:SetShades(shades_input)
	palette:SetColors(colors_input)
	return palette:GetBaseMap()
end

return structs.Register(META)
