local Color = import("goluwa/structs/color.lua")
local ColorPalette = import("goluwa/palette.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local prototype = import("goluwa/prototype.lua")
local DEFAULT_PRIMARY_HEX = "#334155"
local DEFAULT_SIZES = {
	none = 0,
	line = 1,
	XXXS = 4,
	XXS = 6,
	XS = 8,
	S = 12,
	M = 14,
	L = 18,
	XL = 24,
	XXL = 32,
	default = 14,
	line_height = 4,
}
local DEFAULT_FONT_SIZES = {
	XS = 10,
	S = 12,
	M = 14,
	L = 18,
	XL = 24,
	XXL = 30,
	XXXL = 38,
}

local function copy_table(tbl)
	local out = {}

	for key, value in pairs(tbl or {}) do
		out[key] = value
	end

	return out
end

local function merge_tables(base_tbl, override_tbl)
	local merged = copy_table(base_tbl)

	for key, value in pairs(override_tbl or {}) do
		merged[key] = value
	end

	return merged
end

local BaseTheme = prototype.CreateTemplate("ui_theme_base")
BaseTheme.Name = "base"
BaseTheme:GetSet("ThemeContext", nil)
BaseTheme:GetSet("Palette", nil)
BaseTheme:GetSet("Sizes", DEFAULT_SIZES)
BaseTheme:GetSet("FontSizes", DEFAULT_FONT_SIZES)
BaseTheme:GetSet("FontStyles", {})
BaseTheme:GetSet("FontCache", {})
BaseTheme:GetSet("PrimaryColor", nil)
BaseTheme:GetSet("DefaultFontPath", "")

function BaseTheme:New(theme_context)
	local obj = self:CreateObject()
	obj:SetThemeContext(theme_context)
	obj:Initialize()
	return obj
end

function BaseTheme:CopyTable(tbl)
	return copy_table(tbl)
end

function BaseTheme:MergeTables(base_tbl, override_tbl)
	return merge_tables(base_tbl, override_tbl)
end

function BaseTheme:GetPresetTable()
	return {
		palette = self:GetPalette(),
		sizes = self:GetSizes(),
		font_sizes = self:GetFontSizes(),
		font_styles = self:GetFontStyles(),
		font_cache = self:GetFontCache(),
	}
end

function BaseTheme:CreatePalette()
	local primary = self:GetPrimaryColor() or Color.FromHex(DEFAULT_PRIMARY_HEX)
	local semantic_palette = ColorPalette.New()
	semantic_palette:SetShades{
		Color.FromHex("#f8fafc"),
		Color.FromHex("#cbd5e1"),
		Color.FromHex("#080a0e"),
	}
	semantic_palette:SetColors{
		red = Color.FromHex("#dc2626"),
		yellow = Color.FromHex("#d97706"),
		blue = Color.FromHex("#2563eb"),
		green = Color.FromHex("#16a34a"),
		purple = Color.FromHex("#7c3aed"),
		brown = Color.FromHex("#8b5e3c"),
	}
	local base_map = semantic_palette:GetBaseMap()
	semantic_palette:SetMap{
		dashed_underline = Color(0.2, 0.2, 0.2, 0.18),
		property_selection = Color.FromHex("#dbeafe"),
		text_selection = Color.FromHex("#bfdbfe"):SetAlpha(0.85),
		actual_black = Color(0, 0, 0, 1),
		primary = primary,
		secondary = Color.FromHex("#e2e8f0"),
		positive = base_map.green,
		neutral = base_map.yellow,
		negative = base_map.red,
		heading = Color.FromHex("#0f172a"),
		default = Color.FromHex("#0f172a"),
		text = Color.FromHex("#0f172a"),
		text_on_accent = Color.FromHex("#0f172a"),
		foreground = Color.FromHex("#0f172a"),
		text_background = Color.FromHex("#ffffff"),
		main_background = Color.FromHex("#f1f5f9"),
		surface = Color.FromHex("#ffffff"),
		surface_alt = Color.FromHex("#e2e8f0"),
		scrollbar_track = Color(0, 0, 0, 0.08),
		scrollbar = Color(0.1, 0.16, 0.22, 0.35),
		border = Color.FromHex("#cbd5e1"),
		invisible = Color(0, 0, 0, 0),
		clickable_disabled = Color.FromHex("#cbd5e1"),
		button_normal = primary,
		text_disabled = Color.FromHex("#0f172a"):SetAlpha(0.45),
	}
	semantic_palette.AdjustmentOptions = {target_contrast = 4.5}
	return semantic_palette
end

function BaseTheme:Initialize()
	if self:GetPrimaryColor() == nil then
		self:SetPrimaryColor(Color.FromHex(DEFAULT_PRIMARY_HEX))
	end

	if self:GetDefaultFontPath() == "" then
		self:SetDefaultFontPath(fonts.GetDefaultSystemFontPath())
	end

	self:SetPalette(self:CreatePalette())
	self:SetSizes(copy_table(DEFAULT_SIZES))
	self:SetFontSizes(copy_table(DEFAULT_FONT_SIZES))
	self:SetFontStyles{
		heading = {Path = self:GetDefaultFontPath()},
		body_weak = {Path = self:GetDefaultFontPath()},
		body = {Path = self:GetDefaultFontPath()},
		body_strong = {Path = self:GetDefaultFontPath()},
	}
	self:SetFontCache({})
end

function BaseTheme:HasPaletteToken(name)
	local palette = self:GetPalette()

	if not palette or name == nil then return false end

	return palette:GetMap()[name] ~= nil or palette:GetBaseMap()[name] ~= nil
end

function BaseTheme:GetPaletteBaseToken(name)
	local palette = self:GetPalette()

	if not self:HasPaletteToken(name) then return nil end

	return palette:GetMap()[name] or name
end

function BaseTheme:GetSurfaceColor(name)
	name = name or "primary"
	local palette = self:GetPalette()

	if self:HasPaletteToken(name) then return palette:Get(name) end

	return palette and palette:Get("primary")
end

function BaseTheme:GetColor(name, background)
	name = name or "primary"

	if background == nil then
		local theme = self:GetThemeContext()

		if theme then background = theme.GetSurface() end
	end

	local palette = self:GetPalette()
	local token = self:GetPaletteBaseToken(name)
	local background_token = self:GetPaletteBaseToken(background)

	if token ~= nil and token == background_token then background = nil end

	if
		self:HasPaletteToken(name) and
		(
			background == nil or
			self:HasPaletteToken(background)
		)
	then
		return palette:Get(name, background)
	end

	return palette and palette:Get("primary")
end

function BaseTheme:ResolveColor(value, fallback)
	if value == nil then value = fallback end

	if type(value) == "string" then return self:GetColor(value) end

	return value
end

function BaseTheme:ResolveSurfaceColor(value, fallback)
	if value == nil then value = fallback end

	if type(value) == "string" then return self:GetSurfaceColor(value) end

	return value
end

function BaseTheme:GetSize(name)
	local sizes = self:GetSizes()
	name = name or "default"
	return sizes[name] or sizes.default
end

function BaseTheme:GetPadding(name)
	return self:GetSize(name)
end

function BaseTheme:ResolveFontSize(size_name)
	if type(size_name) == "number" then return size_name end

	local font_sizes = self:GetFontSizes()
	return font_sizes[size_name or "M"] or font_sizes.M
end

function BaseTheme:GetFont(name, size_name)
	if name and not size_name then
		local parsed_name, parsed_size = name:match("([^%s]+)%s*(.*)")

		if parsed_size and parsed_size ~= "" then
			name, size_name = parsed_name, parsed_size
		end
	end

	local font_sizes = self:GetFontSizes()
	local font_styles = self:GetFontStyles()

	if font_sizes[name] and not font_styles[name] then
		size_name = name
		name = "body"
	end

	local style = font_styles[name or "body"] or font_styles.body
	local size_val = self:ResolveFontSize(size_name)
	local font_props = {Size = size_val}
	local cache_key
	local font_cache = self:GetFontCache()

	if style.Path then
		font_props.Path = style.Path
		cache_key = "path_" .. style.Path .. "_" .. size_val
	else
		font_props.Name = style.Name or style[1]
		font_props.Weight = style.Weight or style[2]
		cache_key = font_props.Name .. "_" .. (font_props.Weight or "Regular") .. "_" .. size_val
	end

	if not font_cache[cache_key] then
		font_cache[cache_key] = fonts.New(font_props)
	end

	return font_cache[cache_key], size_val
end

function BaseTheme:SetRenderColor(color, alpha_multiplier)
	alpha_multiplier = alpha_multiplier or 1
	render2d.SetColor(color.r, color.g, color.b, color.a * alpha_multiplier)
end

function BaseTheme:DrawRoundRect(x, y, w, h, radius, color, alpha_multiplier)
	render2d.SetTexture(nil)
	self:SetRenderColor(color, alpha_multiplier)

	if radius > 0 then render2d.PushBorderRadius(radius) end

	render2d.DrawRect(x, y, w, h)

	if radius > 0 then render2d.PopBorderRadius() end
end

function BaseTheme:DrawRoundOutline(x, y, w, h, radius, color, alpha_multiplier, thickness)
	render2d.SetTexture(nil)
	self:SetRenderColor(color, alpha_multiplier)
	render2d.PushOutlineWidth(thickness or 1)
	render2d.PushBorderRadius(radius or 0)
	render2d.DrawRect(x, y, w, h)
	render2d.PopBorderRadius()
	render2d.PopOutlineWidth()
end

function BaseTheme:DrawBox(size, opts)
	opts = opts or {}
	local radius = opts.radius or 0
	local fill = opts.fill
	local outline = opts.outline

	if fill ~= nil and (opts.fill_alpha == nil or opts.fill_alpha > 0) then
		self:DrawRoundRect(
			0,
			0,
			size.x,
			size.y,
			radius,
			self:ResolveSurfaceFill(fill, fill),
			opts.fill_alpha
		)
	end

	if outline ~= nil and (opts.outline_alpha == nil or opts.outline_alpha > 0) then
		local outline_color = type(outline) == "string" and self:GetColor(outline, fill) or outline
		self:DrawRoundOutline(
			0,
			0,
			size.x,
			size.y,
			radius,
			outline_color,
			opts.outline_alpha,
			opts.thickness or 1
		)
	end
end

function BaseTheme:DrawInsetBox(x, y, w, h, opts)
	opts = opts or {}
	self:DrawRoundOutline(
		x,
		y,
		w,
		h,
		opts.radius or 0,
		type(opts.outline) == "string" and self:GetColor(opts.outline) or opts.outline,
		opts.outline_alpha,
		opts.thickness or 1
	)
end

function BaseTheme:DrawValueField(draw, opts)
	opts = opts or {}
	local radius = opts.radius or draw.radius or 6
	local fill = opts.fill
	local fill_alpha = opts.fill_alpha

	if fill == nil and opts.state == "editing" then
		fill = opts.edit_fill or "surface_alt"
	elseif fill == nil and opts.state == "hovered" then
		fill = opts.hover_fill or self:GetColor("surface_alt"):Copy():SetAlpha(0.45)
	end

	if fill ~= nil then
		self:DrawBox(draw.size, {fill = fill, fill_alpha = fill_alpha or draw.alpha, radius = radius})
	end

	if opts.outline ~= false and opts.state == "editing" then
		self:DrawBox(
			draw.size,
			{
				outline = opts.outline_color or "border",
				outline_alpha = opts.outline_alpha or draw.alpha,
				radius = radius,
				thickness = opts.thickness or 1,
			}
		)
	end
end

function BaseTheme:DrawPropertyRow(size, opts)
	opts = opts or {}

	if opts.selected then
		return self:DrawSelectionFill(size, opts.selected_color or "property_selection")
	end

	if opts.hovered then
		return self:DrawSelectionFill(size, opts.hover_color or self:GetColor("primary"):Copy():SetAlpha(0.06))
	end

	return self:DrawSelectionFill(size, opts.alternate and "surface_alt" or "surface")
end

function BaseTheme:DrawPropertyPreview(size, opts)
	opts = opts or {}
	self:DrawBox(
		size,
		{
			fill = opts.fill or "surface_alt",
			fill_alpha = opts.fill_alpha,
			outline = opts.outline or "border",
			outline_alpha = opts.outline_alpha or 1,
			radius = opts.radius or 0,
			thickness = opts.thickness or 1,
		}
	)
end

function BaseTheme:ResolveSurfaceFill(color, fallback)
	if color == nil then return self:GetSurfaceColor(fallback or "surface") end

	return self:ResolveSurfaceColor(color)
end

function BaseTheme:GetAccentTint(alpha)
	return self:GetColor("primary"):Copy():SetAlpha(alpha)
end

function BaseTheme:DrawIcon(name, size, opts)
	if name == "disclosure" then
		return self:DrawDisclosureIcon(size, opts)
	elseif name == "dropdown_indicator" then
		return self:DrawDropdownIndicatorIcon(size, opts)
	elseif name == "close" then
		return self:DrawCloseIcon(size, opts)
	end
end

function BaseTheme:DrawDisclosureIcon(size, opts)
	opts = opts or {}
	local icon_size = (opts.size or 10) * 0.6
	local thickness = opts.thickness or 2
	local progress = opts.open_fraction or 0
	local color = opts.color or self:GetColor("text")
	local center = size / 2
	local half = icon_size / 2
	render2d.PushMatrix()
	render2d.Translatef(center.x, center.y)
	render2d.Rotate(math.rad(progress * 90))
	render2d.PushColor(color:Unpack())
	render2d.SetTexture(nil)
	gfx.DrawLine(-half * 0.7, -half, half * 0.7, 0, thickness)
	gfx.DrawLine(-half * 0.7, half, half * 0.7, 0, thickness)
	render2d.PopColor()
	render2d.PopMatrix()
end

function BaseTheme:DrawDropdownIndicatorIcon(size, opts)
	opts = opts or {}
	local icon_size = opts.size or 8
	local thickness = opts.thickness or 2
	local color = opts.color or self:GetColor("text")
	local center = size / 2
	local half = icon_size / 2
	render2d.PushColor(color:Unpack())
	render2d.SetTexture(nil)
	gfx.DrawLine(center.x - half, center.y - half * 0.3, center.x, center.y + half * 0.5, thickness)
	gfx.DrawLine(center.x, center.y + half * 0.5, center.x + half, center.y - half * 0.3, thickness)
	render2d.PopColor()
end

function BaseTheme:DrawCloseIcon(size, opts)
	opts = opts or {}
	local icon_size = opts.size or 8
	local thickness = opts.thickness or 2
	local color = opts.color or self:GetColor("text")
	local center = size / 2
	local half = icon_size / 2
	render2d.PushColor(color:Unpack())
	render2d.SetTexture(nil)
	gfx.DrawLine(center.x - half, center.y - half, center.x + half, center.y + half, thickness)
	gfx.DrawLine(center.x - half, center.y + half, center.x + half, center.y - half, thickness)
	render2d.PopColor()
end

function BaseTheme:UpdateButtonAnimations(state)
	local pnl = state and state.pnl

	if not pnl or not state then return end

	local anim = state.anim
	local hovered = state.hovered and not state.disabled
	local pressed = hovered and state.pressed

	if hovered ~= anim.last_hovered then
		pnl.animation:Animate{
			id = "glow_alpha",
			get = function()
				return anim.glow_alpha
			end,
			set = function(value)
				anim.glow_alpha = value
			end,
			to = hovered and 1 or 0,
			interpolation = "inOutSine",
			time = 0.12,
		}
		anim.last_hovered = hovered
	end

	if pressed ~= anim.last_pressed then
		pnl.animation:Animate{
			id = "press_scale",
			get = function()
				return anim.press_scale
			end,
			set = function(value)
				anim.press_scale = value
			end,
			to = pressed and 1 or 0,
			interpolation = "inOutSine",
			time = 0.08,
		}
		pnl.animation:Animate{
			id = "DrawScaleOffset",
			get = function()
				return pnl.transform:GetDrawScaleOffset()
			end,
			set = function(value)
				pnl.transform:SetDrawScaleOffset(value)
			end,
			to = pressed and (Vec2() + 0.985) or (Vec2(1, 1)),
			interpolation = "inOutSine",
			time = 0.08,
		}
		anim.last_pressed = pressed
	end
end

function BaseTheme:UpdateSliderAnimations(state)
	local pnl = state.pnl

	if not pnl then return end

	local anim = state.anim

	if state.hovered ~= anim.last_hovered then
		pnl.animation:Animate{
			id = "glow_alpha",
			get = function()
				return anim.glow_alpha
			end,
			set = function(value)
				anim.glow_alpha = value
			end,
			to = state.hovered and 1 or 0,
			interpolation = "inOutSine",
			time = 0.15,
		}
		pnl.animation:Animate{
			id = "knob_scale",
			get = function()
				return anim.knob_scale
			end,
			set = function(value)
				anim.knob_scale = value
			end,
			to = state.hovered and 1.2 or 1,
			interpolation = {
				type = "spring",
				bounce = 0.5,
				duration = 80,
			},
		}
		anim.last_hovered = state.hovered
	end
end

function BaseTheme:UpdateCheckboxAnimations(state)
	local pnl = state.pnl

	if not pnl then return end

	local anim = state.anim

	if state.hovered ~= anim.last_hovered then
		pnl.animation:Animate{
			id = "glow_alpha",
			get = function()
				return anim.glow_alpha
			end,
			set = function(value)
				anim.glow_alpha = value
			end,
			to = state.hovered and 1 or 0,
			interpolation = "inOutSine",
			time = 0.15,
		}
		anim.last_hovered = state.hovered
	end

	if state.value ~= anim.last_value then
		pnl.animation:Animate{
			id = "check_anim",
			get = function()
				return anim.check_anim
			end,
			set = function(value)
				anim.check_anim = value
			end,
			to = state.value and 1 or 0,
			interpolation = {
				type = "spring",
				bounce = 0.4,
				duration = 100,
			},
		}
		anim.last_value = state.value
	end
end

function BaseTheme:DrawButton(size, state)
	local anim = state.anim
	local radius = 10
	local fill
	local border = self:GetColor("border")

	if state.disabled then
		fill = self:GetColor("clickable_disabled")
		self.surface_color = "clickable_disabled"
	elseif state.mode == "outline" then
		fill = self:GetColor("surface")
	elseif state.pressed then
		fill = self:GetColor("secondary")
		self.surface_color = "secondary"
	elseif state.active then
		fill = self:GetAccentTint(0.14)
	elseif state.hovered then
		fill = self:GetAccentTint(0.08)
	else
		fill = self:GetColor("primary")
		self.surface_color = "primary"
	end

	if state.mode == "outline" then
		self:DrawRoundRect(0, 0, size.x, size.y, radius, fill, 0.35 + anim.glow_alpha * 0.15)
	else
		self:DrawRoundRect(0, 0, size.x, size.y, radius, fill)
	end

	if state.active and not state.disabled then
		self:DrawRoundOutline(0, 0, size.x, size.y, radius, self:GetColor("primary"), 0.6, 1)
	else
		self:DrawRoundOutline(0, 0, size.x, size.y, radius, border, 0.55, 1)
	end
end

function BaseTheme:DrawButtonPost(size, state)
	self.surface_color = nil
	local anim = state.anim

	if not state.hovered or state.disabled then return end

	local radius = 10
	self:DrawRoundRect(0, 0, size.x, size.y, radius, self:GetColor("primary"), anim.glow_alpha * 0.5, 1)
end

function BaseTheme:DrawMenuButton(size, state, opts)
	opts = opts or {}
	local radius = opts.radius or 4
	local fill = self:GetColor("invisible")
	local hovered_alpha = opts.hovered_alpha or 0.18
	local pressed_alpha = opts.pressed_alpha or 0.28
	local active_border_alpha = opts.active_border_alpha or 0.7

	if state.disabled then
		fill = self:GetColor("invisible")
	elseif state.pressed then
		fill = self:GetColor("primary"):Copy():SetAlpha(pressed_alpha)
	elseif state.active or state.hovered then
		fill = self:GetColor("primary"):Copy():SetAlpha(hovered_alpha)
	end

	self:DrawBox(size, {fill = fill, radius = radius})

	if state.active and not state.disabled then
		self:DrawBox(size, {outline = "border", radius = radius, outline_alpha = active_border_alpha})
	end
end

function BaseTheme:DrawPanelFill(size, color, alpha, radius)
	self:DrawBox(size, {fill = color, fill_alpha = alpha, radius = radius or 0})
end

function BaseTheme:DrawPanelOutline(size, color, alpha, radius, thickness)
	self:DrawBox(
		size,
		{
			outline = color or "border",
			outline_alpha = alpha or 1,
			radius = radius or 0,
			thickness = thickness or 1,
		}
	)
end

function BaseTheme:DrawPanelFillOutline(size, fill_color, outline_color, opts)
	opts = opts or {}
	self:DrawPanelFill(size, fill_color, opts.fill_alpha, opts.radius)
	self:DrawPanelOutline(size, outline_color or "border", opts.outline_alpha, opts.radius, opts.thickness)
end

function BaseTheme:DrawSelectionFill(size, color, alpha)
	self:DrawPanelFill(size, self:ResolveColor(color, color or "primary"), alpha, 0)
end

function BaseTheme:DrawTreeGuideLines(size, meta, opts)
	opts = opts or {}
	local toggle_size = opts.toggle_size or 0
	local guide_step = opts.guide_step or 0
	local center_x = meta.level * guide_step + math.floor(toggle_size / 2)
	local center_y = math.floor(size.y / 2)
	local line_start_x = opts.line_start_x or center_x
	self:SetRenderColor(self:GetColor(opts.line_color or "border"), opts.alpha)
	render2d.SetTexture(nil)

	for level = 1, #(meta.continuations or {}) do
		if meta.continuations[level] then
			local x = (level - 1) * guide_step + math.floor(toggle_size / 2)
			render2d.DrawRect(x, 0, 1, size.y)
		end
	end

	if meta.level > 0 then render2d.DrawRect(center_x, 0, 1, center_y + 1) end

	if not meta.is_last then
		render2d.DrawRect(center_x, center_y, 1, size.y - center_y)
	end

	render2d.DrawRect(line_start_x, center_y, math.max(1, size.x - line_start_x), 1)
	return center_x, center_y
end

function BaseTheme:DrawTreeToggle(size, meta, opts)
	opts = opts or {}
	local box_size = opts.box_size or 0
	local toggle_size = opts.toggle_size or box_size
	local center_x, center_y = self:DrawTreeGuideLines(
		size,
		meta,
		{
			line_color = opts.line_color,
			alpha = opts.alpha,
			toggle_size = toggle_size,
			guide_step = opts.guide_step or 0,
			line_start_x = opts.line_start_x,
		}
	)
	local half_box = math.floor(box_size / 2)
	local box_x = center_x - half_box
	local box_y = center_y - half_box
	self:DrawInsetBox(
		box_x,
		box_y,
		box_size,
		box_size,
		{
			outline = opts.box_outline or "border",
			outline_alpha = 1,
			radius = 0,
			thickness = 1,
		}
	)
	self:DrawRoundRect(box_x, box_y, box_size, box_size, 0, self:GetColor(opts.box_fill or "surface"))
	self:SetRenderColor(self:GetColor(opts.glyph_color or "text"), opts.glyph_alpha)
	render2d.SetTexture(nil)
	render2d.DrawRect(box_x + 2, center_y, math.max(1, box_size - 4), 1)

	if not opts.expanded then
		render2d.DrawRect(center_x, box_y + 2, 1, math.max(1, box_size - 4))
	end

	return center_x, center_y
end

function BaseTheme:DrawDropIndicator(size, opts)
	opts = opts or {}
	self:SetRenderColor(self:GetColor(opts.color or "primary"), opts.alpha)
	render2d.SetTexture(nil)

	if opts.source then
		self:DrawRoundOutline(
			0,
			0,
			math.max(1, size.x),
			math.max(1, size.y),
			0,
			self:GetColor(opts.color or "primary"),
			opts.alpha,
			1
		)
	end

	if opts.position == "inside" then
		self:DrawRoundOutline(
			0,
			0,
			math.max(1, size.x),
			math.max(1, size.y),
			0,
			self:GetColor(opts.color or "primary"),
			opts.alpha,
			2
		)
	elseif opts.position == "before" then
		render2d.DrawRect(0, 0, math.max(1, size.x), opts.thickness or 2)
	elseif opts.position == "after" then
		render2d.DrawRect(
			0,
			math.max(0, size.y - (opts.thickness or 2)),
			math.max(1, size.x),
			opts.thickness or 2
		)
	end
end

function BaseTheme:DrawPreviewTileFrame(size, opts)
	opts = opts or {}
	local radius = opts.radius or 16
	local inset = opts.inset or 0
	local outline_alpha = opts.outline_alpha or 0.05
	self:DrawBox(
		size,
		{
			fill = opts.fill_color or self:GetColor("actual_black"):Copy():SetAlpha(1),
			fill_alpha = opts.fill_alpha,
			outline = Color(1, 1, 1, outline_alpha),
			radius = radius,
			thickness = opts.thickness or 1,
		}
	)

	if inset > 0 then
		self:DrawInsetBox(
			inset,
			inset,
			size.x - inset * 2,
			size.y - inset * 2,
			{
				radius = math.max(0, radius - inset),
				outline = Color(1, 1, 1, opts.inset_outline_alpha or 0.4),
				outline_alpha = 1,
				thickness = opts.thickness or 1,
			}
		)
	end
end

function BaseTheme:DrawSurface(draw, color)
	self:DrawPanelFill(draw.size, color or "surface", draw.alpha, draw.radius)
end

function BaseTheme:DrawSlider(size, state)
	local anim = state.anim

	if state.hovered then self:UpdateSliderAnimations(state) end

	local knob_w = self:GetSize("S")
	local knob_h = self:GetSize("S")
	local track = self:GetColor("surface_alt")
	local accent = self:GetColor("primary")
	local border = self:GetColor("border")
	local value = state.value
	local min_value = state.min
	local max_value = state.max
	local knob_x = 0
	local knob_y = 0

	if state.mode == "2d" then
		local normalized_x = (value.x - min_value.x) / (max_value.x - min_value.x)
		local normalized_y = (value.y - min_value.y) / (max_value.y - min_value.y)
		self:DrawRoundRect(0, 0, size.x, size.y, 6, self:GetColor("surface"))
		self:DrawRoundOutline(0, 0, size.x, size.y, 6, border, 1, 1)
		knob_x = normalized_x * (size.x - knob_w)
		knob_y = normalized_y * (size.y - knob_h)
	elseif state.mode == "vertical" then
		local normalized = (value - min_value) / (max_value - min_value)
		local track_w = self:GetSize("XXS")
		local track_x = (size.x - track_w) / 2
		self:DrawRoundRect(track_x, knob_h / 2, track_w, size.y - knob_h, track_w / 2, track)
		self:DrawRoundRect(track_x, knob_h / 2, track_w, normalized * (size.y - knob_h), track_w / 2, accent)
		knob_x = (size.x - knob_w) / 2
		knob_y = normalized * (size.y - knob_h)
	else
		local normalized = (value - min_value) / (max_value - min_value)
		local track_h = self:GetSize("XXS")
		local track_y = (size.y - track_h) / 2
		self:DrawRoundRect(knob_w / 2, track_y, size.x - knob_w, track_h, track_h / 2, track)
		self:DrawRoundRect(knob_w / 2, track_y, normalized * (size.x - knob_w), track_h, track_h / 2, accent)
		knob_x = normalized * (size.x - knob_w)
		knob_y = (size.y - knob_h) / 2
	end

	local scaled_w = knob_w * anim.knob_scale
	local scaled_h = knob_h * anim.knob_scale
	local offset_x = (scaled_w - knob_w) / 2
	local offset_y = (scaled_h - knob_h) / 2
	self:DrawRoundRect(
		knob_x - offset_x,
		knob_y - offset_y,
		scaled_w,
		scaled_h,
		math.floor(scaled_h / 2),
		self:GetColor("surface")
	)
	self:DrawRoundOutline(
		knob_x - offset_x,
		knob_y - offset_y,
		scaled_w,
		scaled_h,
		math.floor(scaled_h / 2),
		border,
		1,
		1
	)

	if state.hovered then
		self:DrawRoundOutline(
			knob_x - offset_x,
			knob_y - offset_y,
			scaled_w,
			scaled_h,
			math.floor(scaled_h / 2),
			accent,
			anim.glow_alpha * 0.45,
			1
		)
	end
end

function BaseTheme:DrawCheckbox(size, state)
	local anim = state.anim

	if state.hovered then self:UpdateCheckboxAnimations(state) end

	local box_size = self:GetSize("M")
	local x = 0
	local y = (size.y - box_size) / 2
	self:DrawRoundRect(x, y, box_size, box_size, 4, self:GetColor("surface"))
	self:DrawRoundOutline(x, y, box_size, box_size, 4, self:GetColor("border"), 1, 1)

	if anim.check_anim > 0.01 then
		local inset = 3 + (1 - anim.check_anim) * 3
		self:DrawRoundRect(
			x + inset,
			y + inset,
			box_size - inset * 2,
			box_size - inset * 2,
			2,
			self:GetColor("primary"),
			anim.check_anim
		)
	end
end

function BaseTheme:DrawButtonRadio(size, state)
	local anim = state.anim
	local box_size = self:GetSize("M")
	local x = 0
	local y = (size.y - box_size) / 2
	local radius = math.floor(box_size / 2)
	self:DrawRoundRect(x, y, box_size, box_size, radius, self:GetColor("surface"))
	self:DrawRoundOutline(x, y, box_size, box_size, radius, self:GetColor("border"), 1, 1)

	if anim.check_anim > 0.01 then
		local dot = box_size * 0.42 * anim.check_anim
		local dot_x = x + box_size / 2 - dot / 2
		local dot_y = y + box_size / 2 - dot / 2
		self:DrawRoundRect(dot_x, dot_y, dot, dot, math.floor(dot / 2), self:GetColor("primary"))
	end
end

function BaseTheme:DrawFrame(draw, emphasis)
	local size = draw.size
	local radius = self:GetSize("XS")
	self:DrawBox(size, {fill = "surface", fill_alpha = draw.alpha, radius = radius})
end

function BaseTheme:DrawFramePost(draw)
	self:DrawBox(
		draw.size,
		{
			outline = "border",
			outline_alpha = draw.alpha,
			radius = self:GetSize("XS"),
			thickness = 1,
		}
	)
end

function BaseTheme:DrawMenuSpacer(size, vertical)
	self:SetRenderColor(self:GetColor("border"), 0.8)
	render2d.SetTexture(nil)

	if vertical then
		render2d.DrawRect(size.x / 2, 0, 1, size.y)
	else
		render2d.DrawRect(0, size.y / 2, size.x, 1)
	end
end

function BaseTheme:DrawHeader(draw)
	local size = draw.size
	self:DrawBox(size, {fill = "surface_alt", fill_alpha = draw.alpha, radius = 0})
	self:SetRenderColor(self:GetColor("border", "surface_alt"), draw.alpha)
	render2d.SetTexture(nil)
	render2d.DrawRect(0, size.y - 1, size.x, 1)
end

function BaseTheme:DrawProgressBar(size, state, color)
	local value = math.clamp(state.value or 0, 0, 1)
	color = self:ResolveSurfaceFill(color, "primary")
	local radius = math.floor(size.y / 2)
	self:DrawBox(size, {fill = "surface_alt", radius = radius})
	self:DrawRoundRect(0, 0, size.x * value, size.y, radius, color)
	self:DrawBox(size, {outline = "border", radius = radius, outline_alpha = 1, thickness = 1})
end

function BaseTheme:DrawDivider(draw)
	local size = draw.size
	self:SetRenderColor(self:GetColor("border"), draw.alpha)
	render2d.SetTexture(nil)

	if size.x > size.y then
		render2d.DrawRect(0, math.floor(size.y / 2), size.x, 1)
	else
		render2d.DrawRect(math.floor(size.x / 2), 0, 1, size.y)
	end
end

return BaseTheme:Register()
