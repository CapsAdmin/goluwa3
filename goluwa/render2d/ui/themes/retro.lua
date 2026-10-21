local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local objects = import("goluwa/objects/objects.lua")
local BaseTheme = import("./base.lua")
local RetroTheme = objects.CreateTemplate("ui_theme_retro")
RetroTheme.Base = BaseTheme
RetroTheme.Name = "retro"
local NOISE_SIZE = 64
local TILE = 4
local GAP = 1
local TITLE_BANDS = {
	{0.16, 0.08, 0.46},
	{0.28, 0.14, 0.74},
	{0.42, 0.28, 0.96},
	{0.62, 0.50, 1.0},
	{0.42, 0.28, 0.96},
	{0.28, 0.14, 0.74},
	{0.16, 0.08, 0.46},
}
local CHECK_POINTS = {{1, 4}, {2, 5}, {3, 6}, {4, 5}, {5, 4}, {6, 3}, {7, 1}}

local function fill(x, y, w, h, c, k, a)
	k = k or 1
	render2d.SetColor(math.min(c.r * k, 1), math.min(c.g * k, 1), math.min(c.b * k, 1), a or c.a)
	render2d.DrawRect(x, y, w, h)
end

local function bevel(x, y, w, h, light, dark, t, k_light, k_dark)
	fill(x, y, w, t, light, k_light)
	fill(x, y + t, t, h - t * 2, light, k_light)
	fill(x, y + h - t, w, t, dark, k_dark)
	fill(x + w - t, y + t, t, h - t * 2, dark, k_dark)
end

local function octagon(x, y, w, h, c, k, cut)
	fill(x + cut, y, w - cut * 2, h, c, k)
	fill(x, y + cut, w, h - cut * 2, c, k)
	fill(x + 1, y + 1, w - 2, h - 2, c, k)
end

function RetroTheme:CreatePalette()
	return self:ConfigurePalette(self.BaseClass.CreatePalette(self))
end

function RetroTheme:ConfigurePalette(palette)
	local ink = Color.FromHex("#07051a")
	local butter = Color.FromHex("#f6f0c4")
	local yellow = Color.FromHex("#ffd83a")
	local orange = Color.FromHex("#c84a1e")
	local violet = Color.FromHex("#4a5cff")
	local lime = Color.FromHex("#7dff3a")
	local red = Color.FromHex("#ff2a3a")
	palette:SetShades{
		ink,
		Color.FromHex("#8c86d8"),
		butter,
	}
	palette:SetColors{
		red = red,
		yellow = yellow,
		blue = violet,
		green = lime,
		purple = Color.FromHex("#c43cff"),
		brown = Color.FromHex("#8a5a2a"),
	}
	palette.AdjustmentOptions = self:MergeTables(palette.AdjustmentOptions, {target_contrast = 3})
	palette:SetMap{
		ink = ink,
		actual_black = ink,
		primary = violet,
		primary_focus = Color.FromHex("#7a88ff"),
		secondary = yellow,
		highlight = Color.FromHex("#2e3cff"),
		lime = lime,
		rust = Color.FromHex("#9a5a28"),
		button_color = orange,
		button_normal = orange,
		underline = Color.FromHex("#7fe9ff"),
		url_color = Color.FromHex("#7fe9ff"),
		dashed_underline = butter:Copy():SetAlpha(0.3),
		property_selection = Color.FromHex("#2e3cff"),
		text_selection = Color.FromHex("#2e3cff"):SetAlpha(0.75),
		text_highlight = Color.FromHex("#facc15"):SetAlpha(0.5),
		positive = lime,
		neutral = yellow,
		negative = red,
		prefab = "purple",
		heading = yellow,
		heading_on_surface = yellow,
		heading_on_header_surface = Color.FromHex("#ffffff"),
		default = butter,
		text = butter,
		text_input = butter,
		foreground = butter,
		text_foreground = butter,
		text_button = Color.FromHex("#fff6d0"),
		text_on_accent = Color.FromHex("#fff6d0"),
		text_on_dark = butter,
		text_on_dark_muted = butter:Copy():SetAlpha(0.7),
		text_disabled = Color.FromHex("#8c86d8"),
		text_on_surface = butter,
		text_on_surface_variant = butter,
		text_on_card = butter,
		text_on_header_surface = Color.FromHex("#ffffff"),
		text_foreground_on_surface = butter,
		text_foreground_on_header_surface = Color.FromHex("#ffffff"),
		background = Color.FromHex("#1b1650"),
		main_background = Color.FromHex("#1b1650"),
		surface = Color.FromHex("#403a9c"),
		surface_alt = Color.FromHex("#4640a8"),
		surface_variant = Color.FromHex("#27226a"),
		surface_pearl = Color.FromHex("#322d80"),
		surface_tile_1 = Color.FromHex("#27226a"),
		surface_tile_2 = Color.FromHex("#2e2878"),
		surface_tile_3 = Color.FromHex("#221e60"),
		card = Color.FromHex("#322d80"),
		header_surface = Color.FromHex("#2c28a0"),
		field = Color.FromHex("#0f0b34"),
		track = Color.FromHex("#0f0b34"),
		bevel_light = Color.FromHex("#a8a4ff"),
		bevel_dark = Color.FromHex("#0a0724"),
		border = Color.FromHex("#0a0724"),
		border_strong = Color.FromHex("#a8a4ff"),
		scrollbar_track = Color.FromHex("#58529e"),
		scrollbar = Color.FromHex("#6c66d8"),
		clickable_disabled = Color.FromHex("#4a466e"),
		invisible = Color(0, 0, 0, 0),
	}
	return palette
end

function RetroTheme:Initialize()
	self.BaseClass.Initialize(self)
	self:SetSizes(
		self:MergeTables(
			self:GetSizes(),
			{
				XXS = 2,
				XS = 6,
				S = 6,
				M = 12,
				L = 16,
				XL = 24,
				XXL = 32,
				icon = 16,
				header_icon = 16,
				toggle_box = 12,
				header_padding = 6,
				default = 8,
			}
		)
	)
	self:SetRadii{none = 0, XS = 0, S = 0, M = 0, L = 0, full = 0}
	self:SetIconStyle{
		StrokeWidth = 3,
		LineCap = "butt",
		LineJoin = "miter",
		MiterLimit = 4,
		Aliased = true,
	}
	self:SetFontSizes(
		self:MergeTables(
			self:GetFontSizes(),
			{
				XS = 11,
				S = 11,
				M = 11,
				L = 22,
				XL = 22,
				XXL = 33,
				XXXL = 44,
			}
		)
	)
	self:SetFontStyles(
		self:MergeTables(
			self:GetFontStyles(),
			{
				heading = {"Pixelify Sans", "Bold", Aliased = true},
				body_weak = {"Pixelify Sans", "Regular", Aliased = true},
				body = {"Pixelify Sans", "Regular", Aliased = true},
				body_strong = {"Pixelify Sans", "Bold", Aliased = true},
			}
		)
	)
	self:SetFontCache({})
	local assets = import("goluwa/assets.lua")
	self.Textures = {
		Noise = assets.GetTexture("textures/render/retro_noise.lua", {config = {size = NOISE_SIZE}}),
		Checker = assets.GetTexture("textures/render/retro_checker.lua"),
	}
end

function RetroTheme:GetTextShadow(foreground)
	if foreground.r * 0.3 + foreground.g * 0.59 + foreground.b * 0.11 > 0.5 then
		return 1, 1, self:GetColor("ink")
	end

	return 1, 1, self:GetColor("bevel_light"):Copy():SetAlpha(0.55)
end

function RetroTheme:ResolveButtonStyleContext(state)
	local context = self.BaseClass.ResolveButtonStyleContext(self, state)

	if context.foreground_token == "text_on_accent" then
		local c = self:GetColor(context.background_token)

		if c.r * 0.3 + c.g * 0.59 + c.b * 0.11 > 0.5 then
			context.foreground_token = "ink"
		end
	elseif context.foreground_token == "primary" then
		context.foreground_token = "secondary"
	end

	return context
end

function RetroTheme:GetScrollbarWidth()
	return 14
end

function RetroTheme:GetScrollbarCollapsedWidth()
	return self:GetScrollbarWidth()
end

function RetroTheme:GetScrollbarMargin()
	return 0
end

function RetroTheme:UpdateButtonAnimations(pnl) end

function RetroTheme:UpdateCheckboxAnimations(pnl) end

function RetroTheme:UpdateSliderAnimations(pnl) end

function RetroTheme:DrawTiled(texture, tile, x, y, w, h, color, alpha)
	render2d.DrawShape{
		x = x,
		y = y,
		w = w,
		h = h,
		color = color,
		alpha = alpha,
		texture = texture,
		color_uv = {x = 0, y = 0, w = w / tile, h = h / tile},
		int = true,
	}
	render2d.SetTexture(nil)
end

function RetroTheme:DrawSlab(x, y, w, h, color, pressed, hovered, t)
	t = t or 2
	local ink = self:GetColor("ink")
	local light = self:GetColor("bevel_light")
	local dark = self:GetColor("bevel_dark")
	local k = hovered and 1.2 or 1
	fill(x, y, w, h, ink)
	fill(x + 1, y + 1, w - 2, h - 2, color, pressed and 0.8 or k)

	if pressed then
		bevel(x + 1, y + 1, w - 2, h - 2, dark, light, t, 1, 0.7)
		return
	end

	local inner = t + 1
	local iw, ih = w - inner * 2, h - inner * 2

	if ih <= iw then
		local half = math.floor(ih / 2)
		fill(x + inner, y + inner, iw, half, color, k * 1.22)
		fill(x + inner, y + inner + half, iw, ih - half, color, k * 0.9)
	else
		local half = math.floor(iw / 2)
		fill(x + inner, y + inner, half, ih, color, k * 1.22)
		fill(x + inner + half, y + inner, iw - half, ih, color, k * 0.9)
	end

	bevel(x + 1, y + 1, w - 2, h - 2, light, dark, t, 0.9, 0.55)
end

function RetroTheme:DrawSunken(x, y, w, h, color)
	local ink = self:GetColor("ink")
	local light = self:GetColor("bevel_light")
	local dark = self:GetColor("bevel_dark")
	fill(x, y, w, h, light, 0.8)
	fill(x, y, w - 1, h - 1, dark)
	fill(x + 1, y + 1, w - 2, h - 2, color or self:GetColor("field"))
	fill(x + 1, y + 1, w - 2, 1, ink)
	fill(x + 1, y + 1, 1, h - 2, ink)
end

function RetroTheme:DrawSurface(size, color)
	render2d.SetTexture(nil)
	self:DrawSunken(0, 0, math.floor(size.x), math.floor(size.y), self:ResolveColor(color, "field"))
end

function RetroTheme:DrawFrame(size, emphasis)
	local surface = self:GetColor(emphasis == 2 and "surface_variant" or "surface")
	self:DrawTiled(self.Textures.Noise, NOISE_SIZE, 0, 0, size.x, size.y, surface:Copy():SetAlpha(1), 1)
end

function RetroTheme:DrawFramePost(size, emphasis)
	local w, h = math.floor(size.x), math.floor(size.y)
	local ink = self:GetColor("ink")
	local light = self:GetColor("bevel_light")
	local dark = self:GetColor("bevel_dark")
	render2d.SetTexture(nil)

	if emphasis == 1 then
		bevel(0, 0, w, h, dark, light, 2, 1, 0.8)
		return
	elseif emphasis == 0 then
		bevel(0, 0, w, h, ink, ink, 1)
		bevel(1, 1, w - 2, h - 2, light, dark, 1, 0.8, 1)
		return
	elseif emphasis == 2 then
		bevel(0, 0, w, h, ink, ink, 1)
		bevel(1, 1, w - 2, h - 2, light, dark, 2, 1, 0.8)
		return
	end

	local rust = self:GetColor("rust")
	bevel(0, 0, w, h, ink, ink, 1)
	bevel(1, 1, w - 2, h - 2, rust, rust, 4, 1, 1)
	self:DrawTiled(self.Textures.Noise, NOISE_SIZE, 1, 1, w - 2, 4, rust, 0.9)
	self:DrawTiled(self.Textures.Noise, NOISE_SIZE, 1, h - 5, w - 2, 4, rust, 0.9)
	self:DrawTiled(self.Textures.Noise, NOISE_SIZE, 1, 5, 4, h - 10, rust, 0.9)
	self:DrawTiled(self.Textures.Noise, NOISE_SIZE, w - 5, 5, 4, h - 10, rust, 0.9)
	bevel(1, 1, w - 2, h - 2, rust, rust, 1, 1.6, 0.5)
	bevel(5, 5, w - 10, h - 10, dark, rust, 1, 1, 1.5)
	bevel(4, 4, w - 8, h - 8, ink, ink, 1)

	for i = 0, 3 do
		local x = i % 2 == 0 and 3 or w - 4
		local y = i < 2 and 3 or h - 4
		fill(x - 1, y - 1, 3, 3, ink)
		fill(x - 1, y - 1, 1, 1, rust, 1.9)
		fill(x, y, 1, 1, rust, 0.6)
	end
end

function RetroTheme:DrawHeader(size, emphasis)
	local w, h = math.floor(size.x), math.floor(size.y)
	local ink = self:GetColor("ink")
	local rust = self:GetColor("rust")
	render2d.SetTexture(nil)
	fill(0, 0, w, h, ink)
	self:DrawTiled(self.Textures.Noise, NOISE_SIZE, 1, 1, w - 2, h - 1, rust, 1)
	fill(1, 1, w - 2, 1, rust, 1.9)
	fill(1, 1, 1, h - 1, rust, 1.9)
	fill(w - 2, 2, 1, h - 2, rust, 0.55)
	local plate_x, plate_y, plate_w, plate_h = 3, 3, w - 6, h - 4
	fill(plate_x, plate_y, plate_w, plate_h, ink)
	local band_h = (plate_h - 2) / #TITLE_BANDS

	for i, c in ipairs(TITLE_BANDS) do
		local y1 = plate_y + 1 + math.floor((i - 1) * band_h)
		local y2 = plate_y + 1 + math.floor(i * band_h)
		render2d.SetColor(c[1], c[2], c[3], 1)
		render2d.DrawRect(plate_x + 1, y1, plate_w - 2, y2 - y1)
	end

	fill(plate_x + 1, plate_y + 1, plate_w - 2, 1, self:GetColor("bevel_dark"))
	fill(plate_x + 1, plate_y + 1, 1, plate_h - 2, self:GetColor("bevel_dark"))
	fill(
		plate_x + 1,
		plate_y + plate_h - 2,
		plate_w - 2,
		1,
		self:GetColor("bevel_light"),
		0.8
	)
	fill(
		plate_x + plate_w - 2,
		plate_y + 1,
		1,
		plate_h - 2,
		self:GetColor("bevel_light"),
		0.8
	)
end

function RetroTheme:DrawButton(size, state)
	if state.mode == "menu" then
		return self:DrawMenuButton(size, state)
	elseif state.mode == "tab" then
		return self:DrawTabButton(size, state)
	end

	local w, h = math.floor(size.x), math.floor(size.y)
	local pressed = (state.pressed or state.active) and not state.disabled
	local hovered = state.hovered and not state.disabled
	render2d.SetTexture(nil)

	if state.disabled then
		fill(0, 0, w, h, self:GetColor("ink"))
		fill(1, 1, w - 2, h - 2, self:GetColor("clickable_disabled"))
		return
	end

	if state.mode == "text" then
		if hovered or pressed then
			local c = self:GetColor(state.button_color or "highlight")
			fill(0, 0, w, h, c, pressed and 0.8 or 1, 0.85)
			bevel(0, 0, w, h, self:GetColor("ink"), self:GetColor("ink"), 1)
		end

		return
	end

	if state.mode == "outline" then
		local c = self:GetColor("surface_variant")

		if hovered then c = self:GetColor("surface_alt") end

		self:DrawSlab(0, 0, w, h, c, pressed, false)
		return
	end

	self:DrawSlab(0, 0, w, h, self:GetColor(state.button_color or "button_color"), pressed, hovered)
end

function RetroTheme:DrawMenuButton(size, state)
	if state.pressed or state.selected or state.active or state.hovered then
		render2d.SetTexture(nil)
		fill(0, 0, math.floor(size.x), math.floor(size.y), self:GetColor("highlight"))
	end
end

function RetroTheme:DrawTabButton(size, state)
	local w, h = math.floor(size.x), math.floor(size.y)
	local ink = self:GetColor("ink")
	local light = self:GetColor("bevel_light")
	local dark = self:GetColor("bevel_dark")
	local surface = self:GetColor("surface_alt")
	render2d.SetTexture(nil)

	if state.active then
		fill(0, 0, w, h, ink)
		fill(1, 1, w - 2, h, surface, 1.15)
		fill(1, 1, w - 2, 2, light, 0.9)
		fill(1, 1, 2, h, light, 0.9)
		fill(w - 3, 3, 2, h, dark)
		return
	end

	local y = 3
	fill(0, y, w, h - y, ink)
	fill(
		1,
		y + 1,
		w - 2,
		h - y,
		self:GetColor("surface_variant"),
		state.hovered and 1.3 or 1
	)
	fill(1, y + 1, w - 2, 1, light, 0.6)
	fill(1, y + 1, 1, h - y, light, 0.6)
end

function RetroTheme:DrawTabBar(size)
	render2d.SetTexture(nil)
	fill(0, size.y - 2, size.x, 1, self:GetColor("ink"))
	fill(0, size.y - 1, size.x, 1, self:GetColor("bevel_light"), 0.8)
end

function RetroTheme:DrawCheckbox(size, state)
	local box = self:GetSize("M")
	local y = math.floor((size.y - box) / 2)
	render2d.SetTexture(nil)
	self:DrawSunken(0, y, box, box)

	if state.hovered then
		fill(2, y + 2, box - 4, box - 4, self:GetColor("highlight"), 1, 0.35)
	end

	if state.value then
		local inner = box - 4
		local unit = inner / 8
		local lime = self:GetColor("lime")

		for _, p in ipairs(CHECK_POINTS) do
			fill(
				2 + math.floor(p[1] * unit) - 1,
				y + 2 + math.floor(p[2] * unit) - 1,
				math.ceil(unit * 2),
				math.ceil(unit * 2),
				lime
			)
		end
	end
end

function RetroTheme:DrawButtonRadio(size, state)
	local box = self:GetSize("M")
	local y = math.floor((size.y - box) / 2)
	render2d.SetTexture(nil)
	octagon(0, y, box, box, self:GetColor("bevel_light"), 0.8, 3)
	octagon(0, y, box - 1, box - 1, self:GetColor("bevel_dark"), 1, 3)
	octagon(
		1,
		y + 1,
		box - 2,
		box - 2,
		self:GetColor(state.hovered and "highlight" or "field"),
		1,
		3
	)

	if state.value then
		octagon(3, y + 3, box - 6, box - 6, self:GetColor("lime"), 1, 1)
	end
end

function RetroTheme:DrawSlider(size, state)
	local value, min_value, max_value = state.value, state.min, state.max
	local knob = 10
	local lime = self:GetColor("lime")
	local ink = self:GetColor("ink")
	local button = self:GetColor("button_color")
	render2d.SetTexture(nil)

	if state.mode == "2d" then
		local w, h = math.floor(size.x), math.floor(size.y)
		self:DrawSunken(0, 0, w, h)
		local x = (value.x - min_value.x) / (max_value.x - min_value.x) * (w - knob)
		local y = (value.y - min_value.y) / (max_value.y - min_value.y) * (h - knob)
		self:DrawSlab(math.floor(x), math.floor(y), knob, knob, button, state.pressed, state.hovered)
		return
	end

	local normalized = (value - min_value) / (max_value - min_value)

	if state.mode == "vertical" then
		local track_w = 6
		local tx = math.floor((size.x - track_w) / 2)
		local usable = size.y - knob
		self:DrawSunken(tx, 0, track_w, math.floor(size.y), nil)
		local fill_h = math.floor(normalized * usable)

		for y = 2, knob / 2 + fill_h, TILE + GAP do
			fill(tx + 2, y, track_w - 4, TILE, lime)
		end

		self:DrawSlab(
			math.floor((size.x - 18) / 2),
			math.floor(normalized * usable),
			18,
			knob,
			button,
			state.pressed,
			state.hovered
		)
		return
	end

	local track_h = 6
	local ty = math.floor((size.y - track_h) / 2)
	local usable = size.x - knob
	self:DrawSunken(0, ty, math.floor(size.x), track_h)

	for x = 2, knob / 2 + normalized * usable, TILE + GAP do
		fill(x, ty + 2, TILE, track_h - 4, lime)
	end

	self:DrawSlab(
		math.floor(normalized * usable),
		math.floor((size.y - 18) / 2),
		knob,
		18,
		button,
		state.pressed,
		state.hovered
	)
end

function RetroTheme:DrawProgressBar(size, state, color)
	local w, h = math.floor(size.x), math.floor(size.y)
	local value = math.clamp(state.value or 0, 0, 1)
	local brick = self:ResolveSurfaceFill(color, "lime")
	render2d.SetTexture(nil)
	self:DrawSunken(0, 0, w, h)
	local right = 2 + (w - 4) * value

	for x = 2, right - 1, 8 do
		local bw = math.min(7, right - x)
		fill(x, 2, bw, h - 4, brick, 0.55)
		fill(x, 2, bw, math.ceil((h - 4) / 2), brick, 1.15)
		fill(x, 2, bw, 1, brick, 1.6)
	end
end

function RetroTheme:DrawDivider(size)
	render2d.SetTexture(nil)

	if size.x > size.y then
		local y = math.floor(size.y / 2) - 1
		fill(0, y, size.x, 1, self:GetColor("bevel_dark"))
		fill(0, y + 1, size.x, 1, self:GetColor("bevel_light"), 0.8)
	else
		local x = math.floor(size.x / 2) - 1
		fill(x, 0, 1, size.y, self:GetColor("bevel_dark"))
		fill(x + 1, 0, 1, size.y, self:GetColor("bevel_light"), 0.8)
	end
end

function RetroTheme:DrawMenuSpacer(size, vertical)
	render2d.SetTexture(nil)

	if vertical then
		self:DrawDivider(Vec2(size.x, size.y + size.x))
	else
		self:DrawDivider(Vec2(size.x + size.y, size.y))
	end
end

function RetroTheme:DrawMenuContainer(size)
	local w, h = math.floor(size.x), math.floor(size.y)
	render2d.SetTexture(nil)
	fill(0, 0, w, h, self:GetColor("ink"))
	fill(1, 1, w - 2, h - 2, self:GetColor("surface_variant"))
	bevel(
		1,
		1,
		w - 2,
		h - 2,
		self:GetColor("bevel_light"),
		self:GetColor("bevel_dark"),
		2,
		0.9,
		1
	)
end

function RetroTheme:DrawTreeToggle(size, meta, opts)
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
	self:DrawSlab(x, y, box, box, self:GetColor("surface_alt"), false, false)
	fill(x + 3, y + math.floor(box / 2) - 1, box - 6, 2, glyph)

	if not opts.expanded then
		fill(x + math.floor(box / 2) - 1, y + 3, 2, box - 6, glyph)
	end

	return center_x, center_y
end

function RetroTheme:DrawScrollbarTrack(size)
	local w, h = math.floor(size.x), math.floor(size.y)
	render2d.SetTexture(nil)
	fill(0, 0, w, h, self:GetColor("ink"))
	self:DrawTiled(self.Textures.Checker, 2, 1, 1, w - 2, h - 2, self:GetColor("scrollbar_track"), 1)
end

function RetroTheme:DrawScrollbarHandle(size, pressed, hovered)
	local w, h = math.floor(size.x), math.floor(size.y)
	self:DrawSlab(0, 0, w, h, self:GetColor("scrollbar"), pressed, hovered, 1)
	local ink = self:GetColor("bevel_dark")
	local light = self:GetColor("bevel_light")
	local long = math.max(w, h)

	if long < 28 then return end

	local short = math.min(w, h)
	local length = short - 6
	local mid_x, mid_y = math.floor(w / 2), math.floor(h / 2)

	for i = -1, 1 do
		local offset = i * 3

		if h > w then
			fill(3, mid_y + offset, length, 1, ink)
			fill(3, mid_y + offset + 1, length, 1, light, 0.8)
		else
			fill(mid_x + offset, 3, 1, length, ink)
			fill(mid_x + offset + 1, 3, 1, length, light, 0.8)
		end
	end
end

function RetroTheme:DrawScrollbarButton(size, direction, pressed, hovered)
	local w, h = math.floor(size.x), math.floor(size.y)
	self:DrawSlab(0, 0, w, h, self:GetColor("scrollbar"), pressed, hovered, 1)
	local shift = pressed and 1 or 0
	self:DrawArrow(shift, shift, w, h, direction, self:GetColor("ink"), 2)
end

function RetroTheme:DrawAutoscrollMarker(size, vertical, horizontal)
	local w, h = math.floor(size.x), math.floor(size.y)
	local ink = self:GetColor("ink")
	local icon = math.floor(math.min(w, h) * 0.38)
	local arrow = self:GetColor("text")
	render2d.SetTexture(nil)
	octagon(0, 0, w, h, ink, 1, 8)
	octagon(1, 1, w - 2, h - 2, self:GetColor("surface_alt"), 1, 7)
	octagon(math.floor(w / 2 - 3), math.floor(h / 2 - 3), 6, 6, self:GetColor("lime"), 1, 2)

	if vertical then
		self:DrawAutoscrollChevron("chevron_up", w / 2, h * 0.24, icon, arrow)
		self:DrawAutoscrollChevron("chevron_down", w / 2, h * 0.76, icon, arrow)
	end

	if horizontal then
		self:DrawAutoscrollChevron("chevron_left", w * 0.24, h / 2, icon, arrow)
		self:DrawAutoscrollChevron("chevron_right", w * 0.76, h / 2, icon, arrow)
	end
end

function RetroTheme:Draw(pnl)
	local name = pnl.ThemeName or pnl.Name

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

return RetroTheme:Register()
