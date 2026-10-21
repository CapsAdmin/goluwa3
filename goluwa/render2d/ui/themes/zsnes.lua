local bit = require("bit")
local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local objects = import("goluwa/objects/objects.lua")
local glyphs = import("goluwa/render2d/glyphs.lua")
local BaseTheme = import("./base.lua")
local ZsnesTheme = objects.CreateTemplate("ui_theme_zsnes")
ZsnesTheme.Base = BaseTheme
ZsnesTheme.Name = "zsnes"
local PX = 2
local FONT = "bitmap:zsnes:" .. PX
local zsnes_font = import("goluwa/render2d/fonts/zsnes_bitmap.lua")
zsnes_font.shade = function(x, y)
	return 1 - 0.028 * ((4 - y) + (5 - x))
end
glyphs.RegisterBitmapFont(zsnes_font)

local function from_565(c)
	local r = bit.rshift(c, 11)
	local g = bit.band(bit.rshift(c, 5), 63)
	local b = bit.band(c, 31)
	return Color(r / 31, g / 63, b / 31, 1)
end

local function pal16(r, g, b)
	return from_565(
		bit.band(
			bit.bor(bit.lshift(bit.rshift(r, 1), 11), bit.lshift(g, 5), bit.rshift(b, 1)),
			0xFFFF
		)
	)
end

local function window_scale(index, first, last, factor)
	local steps = last - index
	local r, g, b = 8 * 2, 8 * 2, 25 * 2
	r, g, b = r - math.floor(r * factor),
	g - math.floor(g * factor),
	b - math.floor(b * factor)
	return pal16(
		math.max(r - steps * 4, 0),
		math.max(g - steps * 4, 0),
		math.max(b - steps * 4, 0)
	)
end

local function win(index)
	if index <= 152 then return window_scale(index, 148, 152, 0) end

	if index <= 157 then return window_scale(index, 153, 157, 1 / 4) end

	return window_scale(index, 158, 162, 1 / 2)
end

local function gray(index)
	local i = index - 189
	return pal16(math.floor(i * 3 / 2), math.floor(i * 3 / 2), i * 2)
end

local function hex(s)
	return Color.FromHex(s)
end

local MENU_BAR = {
	"#002c88",
	"#003098",
	"#0034a8",
	"#0038b8",
	"#003cc8",
	"#0040d8",
	"#0044e8",
	"#0048f8",
}
local ICON_CLOSE = {
	{0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{0, 216, 216, 216, 216, 216, 216, 216, 0, 0},
	{214, 212, 202, 212, 212, 212, 202, 212, 210, 0},
	{214, 212, 212, 200, 212, 200, 212, 212, 210, 202},
	{214, 212, 212, 212, 198, 212, 212, 212, 210, 202},
	{214, 212, 212, 196, 212, 196, 212, 212, 210, 200},
	{214, 212, 194, 212, 212, 212, 194, 212, 210, 200},
	{0, 208, 208, 208, 208, 208, 208, 208, 198, 198},
	{0, 0, 198, 198, 198, 198, 198, 198, 198, 0},
	{0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
}
local ICON_CHECK_OFF = {
	{0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{0, 220, 219, 218, 217, 216, 215, 0, 0, 0},
	{0, 219, 218, 217, 216, 215, 214, 202, 0, 0},
	{0, 218, 217, 216, 215, 214, 213, 202, 0, 0},
	{0, 217, 216, 215, 214, 213, 212, 202, 0, 0},
	{0, 216, 215, 214, 213, 212, 211, 202, 0, 0},
	{0, 215, 214, 213, 212, 211, 210, 202, 0, 0},
	{0, 0, 202, 202, 202, 202, 202, 202, 0, 0},
}
local ICON_CHECK_ON = {
	{0, 0, 0, 0, 0, 0, 0, 0, 165, 0},
	{0, 0, 0, 0, 0, 0, 0, 165, 0, 0},
	{0, 0, 0, 0, 0, 0, 165, 0, 0, 0},
	{0, 220, 219, 218, 217, 165, 215, 0, 0, 0},
	{0, 165, 165, 217, 165, 165, 214, 202, 0, 0},
	{0, 218, 165, 216, 165, 214, 213, 202, 0, 0},
	{0, 217, 165, 165, 165, 213, 212, 202, 0, 0},
	{0, 216, 215, 165, 213, 212, 211, 202, 0, 0},
	{0, 215, 214, 165, 212, 211, 210, 202, 0, 0},
	{0, 0, 202, 202, 202, 202, 202, 202, 0, 0},
}
local ICON_RADIO_ON = {
	{0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{0, 0, 0, 207, 209, 207, 0, 0, 0, 0},
	{0, 0, 207, 211, 212, 211, 207, 0, 0, 0},
	{0, 207, 211, 214, 216, 214, 211, 207, 0, 0},
	{0, 207, 212, 216, 217, 216, 212, 207, 0, 0},
	{0, 207, 211, 214, 216, 214, 211, 207, 0, 0},
	{0, 0, 207, 211, 212, 211, 207, 0, 0, 0},
	{0, 0, 0, 207, 209, 207, 0, 0, 0, 0},
	{0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
}
local ICON_RADIO_OFF = {
	{0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{0, 0, 0, 207, 205, 207, 0, 0, 0, 0},
	{0, 0, 207, 203, 202, 203, 207, 0, 0, 0},
	{0, 207, 203, 200, 198, 200, 203, 207, 0, 0},
	{0, 207, 202, 198, 197, 198, 202, 207, 0, 0},
	{0, 207, 203, 200, 198, 200, 203, 207, 0, 0},
	{0, 0, 207, 203, 202, 203, 207, 0, 0, 0},
	{0, 0, 0, 207, 205, 207, 0, 0, 0, 0},
	{0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
}
local ICON_KNOB = {
	{0, 0, 0, 0, 216, 0, 0, 0, 0, 0},
	{0, 0, 0, 212, 216, 220, 0, 0, 0, 0},
	{0, 0, 0, 212, 216, 220, 202, 0, 0, 0},
	{0, 0, 212, 212, 216, 218, 220, 0, 0, 0},
	{0, 0, 212, 214, 216, 218, 220, 202, 0, 0},
	{0, 0, 212, 214, 216, 218, 220, 202, 0, 0},
	{0, 0, 0, 212, 216, 220, 202, 202, 0, 0},
	{0, 0, 0, 212, 216, 220, 202, 0, 0, 0},
	{0, 0, 0, 0, 216, 202, 202, 0, 0, 0},
	{0, 0, 0, 0, 0, 202, 0, 0, 0, 0},
}

local function fill(x, y, w, h, c, k, a)
	k = k or 1
	render2d.SetColor(math.min(c.r * k, 1), math.min(c.g * k, 1), math.min(c.b * k, 1), a or c.a)
	render2d.DrawRect(x, y, w, h)
end

local function zfill(x, y, w, h, c, k, a)
	fill(x * PX, y * PX, w * PX, h * PX, c, k, a)
end

local function draw_icon(x, y, icon, red)
	for row = 1, 10 do
		for col = 1, 10 do
			local index = icon[row][col]

			if index ~= 0 then
				zfill(x + col - 1, y + row - 1, 1, 1, index == 165 and red or gray(index))
			end
		end
	end
end

local function gui_button(x, y, w, h, base, pressed)
	local top, left, body, right, bottom

	if pressed then
		top, left, body, right, bottom = base - 18, base - 16, base - 14, base - 12, base - 10
	else
		top, left, body, right, bottom = base - 5, base - 8, base - 11, base - 14, base - 17
	end

	zfill(x, y, w, h, gray(body))
	zfill(x, y, w, 1, gray(top))
	zfill(x, y, 1, h, gray(left))
	zfill(x + w - 1, y + 1, 1, h - 1, gray(right))
	zfill(x, y + h - 1, w - 1, 1, gray(bottom))
end

function ZsnesTheme:CreatePalette()
	return self:ConfigurePalette(self.BaseClass.CreatePalette(self))
end

function ZsnesTheme:ConfigurePalette(palette)
	local face = gray(217)
	local shadow = gray(202)
	local yellow = hex("#a5a200")
	local red = hex("#ce0000")
	local green = hex("#00df00")
	local magenta = hex("#a50052")
	local black = Color(0, 0, 0, 1)
	palette:SetShades{
		black,
		gray(205),
		face,
	}
	palette:SetColors{
		red = red,
		yellow = yellow,
		blue = win(152),
		green = green,
		purple = magenta,
		brown = hex("#8c3d3a"),
	}
	palette.AdjustmentOptions = self:MergeTables(palette.AdjustmentOptions, {target_contrast = 1})
	palette:SetMap{
		ink = black,
		actual_black = black,
		primary = win(152),
		primary_focus = win(152),
		secondary = yellow,
		highlight = magenta,
		lime = green,
		rust = gray(205),
		button_color = gray(206),
		button_normal = gray(206),
		underline = green,
		url_color = green,
		dashed_underline = face:Copy():SetAlpha(0.3),
		property_selection = magenta,
		text_selection = magenta:Copy():SetAlpha(0.85),
		text_highlight = yellow:Copy():SetAlpha(0.5),
		positive = green,
		neutral = yellow,
		negative = red,
		prefab = "purple",
		heading = yellow,
		heading_on_surface = yellow,
		heading_on_header_surface = gray(220),
		default = face,
		text = face,
		text_input = green,
		foreground = face,
		text_foreground = face,
		text_button = face,
		text_on_accent = face,
		text_on_dark = face,
		text_on_dark_muted = face:Copy():SetAlpha(0.7),
		text_disabled = gray(211),
		text_on_surface = face,
		text_on_surface_variant = face,
		text_on_card = face,
		text_on_header_surface = gray(220),
		text_foreground_on_surface = face,
		text_foreground_on_header_surface = gray(220),
		background = win(150),
		main_background = win(150),
		surface = win(150),
		surface_alt = win(152),
		surface_variant = win(148),
		surface_pearl = win(149),
		surface_tile_1 = win(149),
		surface_tile_2 = win(150),
		surface_tile_3 = win(148),
		card = win(149),
		header_surface = gray(205),
		field = black,
		track = black,
		bevel_light = win(152),
		bevel_dark = win(148),
		border = win(148),
		border_strong = win(152),
		scrollbar_track = gray(197),
		scrollbar = gray(202),
		clickable_disabled = gray(197),
		invisible = Color(0, 0, 0, 0),
		menu_face = hex("#585c58"),
		menu_light = hex("#787c78"),
		menu_left = hex("#686c68"),
		menu_right = hex("#484c48"),
		menu_dark = hex("#383c38"),
		menu_text = hex("#c8c8c8"),
		menu_text_shadow = hex("#383430"),
		text_shadow = shadow,
	}
	return palette
end

function ZsnesTheme:Initialize()
	self.BaseClass.Initialize(self)
	self:SetSizes(
		self:MergeTables(
			self:GetSizes(),
			{
				XXS = PX,
				XS = PX * 2,
				S = PX * 3,
				M = PX * 5,
				L = PX * 8,
				XL = PX * 12,
				XXL = PX * 16,
				icon = PX * 8,
				header_icon = PX * 8,
				toggle_box = PX * 12,
				header_padding = PX * 3,
				default = PX * 4,
			}
		)
	)
	self:SetRadii{none = 0, XS = 0, S = 0, M = 0, L = 0, full = 0}
	self:SetIconStyle{
		StrokeWidth = PX,
		LineCap = "butt",
		LineJoin = "miter",
		MiterLimit = 4,
		Aliased = true,
	}
	local sizes = {XS = 8, S = 8, M = 8, L = 16, XL = 16, XXL = 24, XXXL = 32}
	self:SetFontSizes(self:MergeTables(self:GetFontSizes(), sizes))
	self:SetFontStyles(
		self:MergeTables(
			self:GetFontStyles(),
			{
				heading = {Path = FONT},
				body_weak = {Path = FONT},
				body = {Path = FONT},
				body_strong = {Path = FONT},
			}
		)
	)
	self:SetFontCache({})
end

function ZsnesTheme:GetTextShadow(foreground)
	if foreground.r * 0.3 + foreground.g * 0.59 + foreground.b * 0.11 < 0.4 then
		return nil
	end

	if math.abs(foreground.r - foreground.b) < 0.04 then
		return PX, PX, self:GetColor("menu_text_shadow")
	end

	return PX, PX, self:GetColor("text_shadow")
end

function ZsnesTheme:ResolveButtonStyleContext(state)
	local context = self.BaseClass.ResolveButtonStyleContext(self, state)

	if state.mode == "menu" and not state.disabled then
		context.foreground_token = "menu_text"
	elseif context.foreground_token == "primary" then
		context.foreground_token = "heading"
	end

	return context
end

function ZsnesTheme:GetScrollbarWidth()
	return PX * 8
end

function ZsnesTheme:GetScrollbarCollapsedWidth()
	return self:GetScrollbarWidth()
end

function ZsnesTheme:GetScrollbarMargin()
	return 0
end

function ZsnesTheme:UpdateButtonAnimations(pnl) end

function ZsnesTheme:UpdateCheckboxAnimations(pnl) end

function ZsnesTheme:UpdateSliderAnimations(pnl) end

function ZsnesTheme:DrawSunken(x, y, w, h, color)
	fill(x, y, w, h, color or self:GetColor("field"))
	fill(x, y, w, PX, win(148))
	fill(x, y, PX, h, win(149))
	fill(x + PX, y + h - PX, w - PX, PX, win(152))
	fill(x + w - PX, y + PX, PX, h - PX, win(151))
end

function ZsnesTheme:DrawValueField(size, opts)
	opts = opts or {}
	render2d.SetTexture(nil)
	local field = self:GetColor("field")

	if opts.state == "hovered" then
		field = field:Copy()
		field.b = 0.12
	end

	self:DrawSunken(0, 0, math.floor(size.x), math.floor(size.y), field)
end

function ZsnesTheme:DrawSurface(size, color)
	render2d.SetTexture(nil)
	self:DrawSunken(0, 0, math.floor(size.x), math.floor(size.y), self:ResolveColor(color, "field"))
end

function ZsnesTheme:DrawFrame(size, emphasis)
	local w, h = math.floor(size.x), math.floor(size.y)
	render2d.SetTexture(nil)

	if emphasis == 1 then
		return
	elseif emphasis == 2 then
		fill(0, 0, w, h, win(148))
		return
	end

	fill(0, 0, w, h, self:GetColor("surface"))
end

function ZsnesTheme:DrawFramePost(size, emphasis)
	local w, h = math.floor(size.x), math.floor(size.y)
	render2d.SetTexture(nil)

	if emphasis == 1 then
		self:DrawSunken(0, 0, w, h, Color(0, 0, 0, 0))
		return
	elseif emphasis == 0 or emphasis == 2 then
		return
	end

	fill(0, 0, PX, h, win(151))
	fill(w - PX, 0, PX, h, win(149))
	fill(0, h - PX, w, PX, win(148))
end

function ZsnesTheme:DrawHeader(size)
	local w, h = math.floor(size.x), math.floor(size.y)
	render2d.SetTexture(nil)
	local lines = {209, 207, 206, 205, 204, 203, 202, 201, 200, 199}
	local band = h / #lines

	for i, index in ipairs(lines) do
		local y1 = math.floor((i - 1) * band)
		local y2 = math.floor(i * band)
		fill(0, y1, w, y2 - y1, gray(index))
	end

	fill(0, 0, PX, h, gray(205))
	fill(w - PX, 0, PX, h, gray(201))
end

function ZsnesTheme:DrawBarButton(size, state)
	local w, h = math.floor(size.x / PX), math.floor(size.y / PX)
	local open = (state.pressed or state.active or state.hovered) and not state.disabled
	render2d.SetTexture(nil)

	if open then
		zfill(0, 0, w, h, hex("#686460"))
		zfill(0, 0, w, 1, hex("#787470"))
		zfill(0, 0, 1, h - 1, hex("#686460"))
		zfill(w - 1, 1, 1, h - 1, hex("#484440"))
		zfill(0, h - 1, w, 1, hex("#383430"))
	else
		zfill(0, 0, w, h, hex("#484440"))
		zfill(0, 0, w, 1, hex("#383430"))
		zfill(w - 1, 1, 1, h - 1, hex("#686460"))
		zfill(0, h - 1, w, 1, hex("#787470"))
	end
end

function ZsnesTheme:DrawMenuBarFill(size)
	local w, h = math.floor(size.x), math.floor(size.y)
	local count = #MENU_BAR * 2 - 1
	local band = h / count
	render2d.SetTexture(nil)

	for i = 1, count do
		local c = MENU_BAR[i <= #MENU_BAR and i or count - i + 1]
		local y1 = math.floor((i - 1) * band)
		local y2 = math.floor(i * band)
		fill(0, y1, w, y2 - y1, hex(c))
	end
end

function ZsnesTheme:DrawButton(size, state)
	if state.mode == "menu" then
		return self:DrawMenuButton(size, state)
	elseif state.mode == "tab" then
		return self:DrawTabButton(size, state)
	end

	local w, h = math.floor(size.x / PX), math.floor(size.y / PX)
	local pressed = (state.pressed or state.active) and not state.disabled
	local hovered = state.hovered and not state.disabled
	render2d.SetTexture(nil)

	if state.disabled then
		gui_button(0, 0, w, h, 208, false)
		return
	end

	if state.mode == "text" then
		if hovered or pressed then
			zfill(0, 0, w, h, self:GetColor("highlight"), pressed and 0.85 or 1)
		end

		return
	end

	gui_button(0, 0, w, h, hovered and 220 or 217, pressed)
end

function ZsnesTheme:DrawMenuButton(size, state)
	if not (state.pressed or state.selected or state.active or state.hovered) then
		return
	end

	local w, h = math.floor(size.x), math.floor(size.y)
	local magenta = self:GetColor("highlight")
	render2d.SetTexture(nil)
	fill(0, 0, w, h, magenta)
	fill(0, 0, w, PX, magenta, 0.88)
	fill(0, h - PX, w, PX, magenta, 0.88)
end

function ZsnesTheme:DrawTabButton(size, state)
	local w, h = math.floor(size.x / PX), math.floor(size.y / PX)
	render2d.SetTexture(nil)

	if state.active then
		gui_button(0, 0, w, h + 1, 217, false)
		return
	end

	gui_button(0, 2, w, h - 2, state.hovered and 214 or 211, false)
end

function ZsnesTheme:DrawTabBar(size)
	render2d.SetTexture(nil)
	fill(0, size.y - PX, size.x, PX, gray(205))
end

function ZsnesTheme:DrawCheckbox(size, state)
	local y = math.floor((size.y - PX * 10) / 2 / PX)
	render2d.SetTexture(nil)
	draw_icon(0, y, state.value and ICON_CHECK_ON or ICON_CHECK_OFF, self:GetColor("negative"))
end

function ZsnesTheme:DrawButtonRadio(size, state)
	local y = math.floor((size.y - PX * 10) / 2 / PX)
	render2d.SetTexture(nil)
	draw_icon(0, y, state.value and ICON_RADIO_ON or ICON_RADIO_OFF, self:GetColor("negative"))
end

function ZsnesTheme:DrawSlider(size, state)
	local value, min_value, max_value = state.value, state.min, state.max
	render2d.SetTexture(nil)

	if state.mode == "2d" then
		local w, h = math.floor(size.x), math.floor(size.y)
		self:DrawSunken(0, 0, w, h)
		local x = (value.x - min_value.x) / (max_value.x - min_value.x) * (w - PX * 10)
		local y = (value.y - min_value.y) / (max_value.y - min_value.y) * (h - PX * 10)
		draw_icon(math.floor(x / PX), math.floor(y / PX), ICON_KNOB, self:GetColor("negative"))
		return
	end

	local normalized = (value - min_value) / (max_value - min_value)

	if state.mode == "vertical" then
		local x = math.floor(size.x / PX / 2)
		local usable = size.y - PX * 10
		zfill(x, 0, 1, math.floor(size.y / PX), gray(215))
		zfill(x + 1, 1, 1, math.floor(size.y / PX), gray(202))
		draw_icon(x - 5, math.floor(normalized * usable / PX), ICON_KNOB, self:GetColor("negative"))
		return
	end

	local y = math.floor(size.y / PX / 2)
	local usable = size.x - PX * 10
	zfill(0, y, math.floor(size.x / PX), 1, gray(215))
	zfill(1, y + 1, math.floor(size.x / PX), 1, gray(202))
	draw_icon(math.floor(normalized * usable / PX), y - 4, ICON_KNOB, self:GetColor("negative"))
end

function ZsnesTheme:DrawProgressBar(size, state, color)
	local w, h = math.floor(size.x), math.floor(size.y)
	local value = math.clamp(state.value or 0, 0, 1)
	render2d.SetTexture(nil)
	self:DrawSunken(0, 0, w, h)
	local fill_w = math.floor((w - PX * 2) * value / PX) * PX
	fill(PX, PX, fill_w, h - PX * 2, hex("#00df00"))
	fill(PX, PX, fill_w, PX, hex("#00b600"))
end

function ZsnesTheme:DrawDivider(size)
	render2d.SetTexture(nil)

	if size.x > size.y then
		local y = math.floor(size.y / 2 / PX) * PX - PX
		fill(0, y, size.x, PX, self:GetColor("menu_right"))
		fill(0, y + PX, size.x, PX, self:GetColor("menu_left"))
	else
		local x = math.floor(size.x / 2 / PX) * PX - PX
		fill(x, 0, PX, size.y, self:GetColor("menu_right"))
		fill(x + PX, 0, PX, size.y, self:GetColor("menu_left"))
	end
end

function ZsnesTheme:DrawMenuSpacer(size, vertical)
	render2d.SetTexture(nil)

	if vertical then
		self:DrawDivider(Vec2(size.x, size.y + size.x))
	else
		self:DrawDivider(Vec2(size.x + size.y, size.y))
	end
end

function ZsnesTheme:DrawMenuContainer(size)
	local w, h = math.floor(size.x), math.floor(size.y)
	render2d.SetTexture(nil)
	fill(0, 0, w, h, self:GetColor("menu_face"))
	fill(0, 0, w, PX, self:GetColor("menu_light"))
	fill(0, 0, PX, h, self:GetColor("menu_left"))
	fill(0, h - PX, w, PX, self:GetColor("menu_dark"))
	fill(w - PX, PX, PX, h - PX, self:GetColor("menu_right"))
end

function ZsnesTheme:DrawTreeToggle(size, meta, opts)
	opts = opts or {}
	local box = opts.box_size or 0
	local center_x, center_y = self:DrawTreeGuideLines(
		size,
		meta,
		{
			line_color = opts.line_color,
			alpha = opts.alpha,
			toggle_size = opts.toggle_size or box,
			guide_step = opts.guide_step or 0,
			line_start_x = opts.line_start_x,
		}
	)
	local x = center_x - math.floor(box / 2)
	local y = center_y - math.floor(box / 2)
	local glyph = self:GetColor(opts.glyph_color or "text")
	render2d.SetTexture(nil)
	gui_button(x / PX, y / PX, box / PX, box / PX, 217, false)
	fill(x + PX * 2, y + math.floor(box / 2) - PX / 2, box - PX * 4, PX, glyph)

	if not opts.expanded then
		fill(x + math.floor(box / 2) - PX / 2, y + PX * 2, PX, box - PX * 4, glyph)
	end

	return center_x, center_y
end

function ZsnesTheme:DrawScrollbarTrack(size)
	local w, h = math.floor(size.x), math.floor(size.y)
	local shades = {197, 195, 194, 193, 193, 194, 195, 197}
	render2d.SetTexture(nil)

	if h > w then
		for i, index in ipairs(shades) do
			fill((i - 1) * w / 8, 0, w / 8, h, gray(index))
		end
	else
		for i, index in ipairs(shades) do
			fill(0, (i - 1) * h / 8, w, h / 8, gray(index))
		end
	end
end

function ZsnesTheme:DrawScrollbarHandle(size, pressed, hovered)
	local w, h = math.floor(size.x), math.floor(size.y)
	local face = pressed and 200 or hovered and 206 or 202
	render2d.SetTexture(nil)
	fill(0, 0, w, h, gray(face - 2))
	fill(0, 0, w, h, gray(face - 2))

	if h > w then
		fill(0, 0, w, PX, gray(face))
		fill(0, 0, PX, h, gray(face))
		fill(w - PX, 0, PX, h, gray(face))
		fill(0, h - PX, w, PX, gray(face - 6))
	else
		fill(0, 0, PX, h, gray(face))
		fill(0, 0, w, PX, gray(face))
		fill(0, h - PX, w, PX, gray(face))
		fill(w - PX, 0, PX, h, gray(face - 6))
	end
end

function ZsnesTheme:DrawScrollbarButton(size, direction, pressed, hovered)
	local w, h = math.floor(size.x / PX), math.floor(size.y / PX)
	render2d.SetTexture(nil)
	gui_button(0, 0, w, h, hovered and 220 or 217, pressed)
	local shift = pressed and PX or 0
	self:DrawArrow(shift, shift, w * PX, h * PX, direction, gray(pressed and 199 or 197), PX)
end

function ZsnesTheme:DrawAutoscrollMarker(size, vertical, horizontal)
	local w, h = math.floor(size.x / PX), math.floor(size.y / PX)
	local color = gray(197)
	render2d.SetTexture(nil)
	gui_button(0, 0, w, h, 217, false)
	zfill(math.floor((w - 2) / 2), math.floor((h - 2) / 2), 2, 2, color)
	local pw, ph = w * PX, h * PX

	if vertical then
		self:DrawArrow(0, PX * 2, pw, ph * 0.3, "up", color, PX)
		self:DrawArrow(0, ph * 0.7 - PX * 2, pw, ph * 0.3, "down", color, PX)
	end

	if horizontal then
		self:DrawArrow(PX * 2, 0, pw * 0.3, ph, "left", color, PX)
		self:DrawArrow(pw * 0.7 - PX * 2, 0, pw * 0.3, ph, "right", color, PX)
	end
end

function ZsnesTheme:Draw(pnl)
	local name = pnl.ThemeName or pnl.Name

	if name == "menu_bar" then
		return self:DrawMenuBarFill(pnl.transform:GetSize())
	elseif name == "clickable" and pnl.MenuBar then
		return self:DrawBarButton(pnl.transform:GetTotalSize(), pnl:GetState())
	end

	if type(name) == "string" then
		if name:starts_with("scrollbar_track_") then
			return self:DrawScrollbarTrack(pnl.transform:GetTotalSize())
		elseif name:starts_with("scrollbar_handle_") then
			return self:DrawScrollbarHandle(
				pnl.transform:GetTotalSize(),
				pnl:GetState("pressed"),
				pnl:GetState("hovered")
			)
		end
	end

	return self.BaseClass.Draw(self, pnl)
end

return ZsnesTheme:Register()
