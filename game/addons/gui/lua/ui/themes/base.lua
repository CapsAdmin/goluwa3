local Color = import("goluwa/structs/color.lua")
local ColorPalette = import("goluwa/palette.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local prototype = import("goluwa/prototype.lua")
local BaseTheme = prototype.CreateTemplate("ui_theme_base")
BaseTheme.Name = "base"
BaseTheme:GetSet("ThemeContext", nil)
BaseTheme:GetSet("Palette", nil)
BaseTheme:GetSet(
	"Sizes",
	{
		none = 0,
		line = 1,
		XXXS = 2,
		XXS = 4,
		XS = 8,
		S = 12,
		M = 17,
		L = 24,
		LG = 24,
		XL = 32,
		XXL = 48,
		default = 14,
	}
)
BaseTheme:GetSet("Radii", {
	none = 0,
	XS = 2,
	S = 3,
	M = 4,
	L = 6,
	full = 9999,
})
BaseTheme:GetSet(
	"FontSizes",
	{
		XS = 10,
		S = 12,
		M = 14,
		L = 18,
		XL = 24,
		XXL = 30,
		XXXL = 38,
	}
)
BaseTheme:GetSet("FontStyles", {})
BaseTheme:GetSet("FontCache", {})
BaseTheme:GetSet("PrimaryColor", Color.FromHex("#0066cc"))
BaseTheme:GetSet("DefaultFontPath", "")

function BaseTheme:New(theme_context)
	local obj = self:CreateObject()
	obj:SetThemeContext(theme_context)
	obj:Initialize()
	return obj
end

function BaseTheme:MergeTables(base_tbl, override_tbl)
	local merged = table.shallow_copy(base_tbl)

	for key, value in pairs(override_tbl or {}) do
		merged[key] = value
	end

	return merged
end

function BaseTheme:CreatePalette()
	local primary = self:GetPrimaryColor()
	local text = Color.FromHex("#1d1d1f")
	local text_muted = Color.FromHex("#7a7a7a")
	local surface = Color.FromHex("#ffffff")
	local surface_alt = Color.FromHex("#f5f5f7")
	local semantic_palette = ColorPalette.New()
	semantic_palette:SetShades{
		Color.FromHex("#f5f5f7"), -- parchment
		Color.FromHex("#272729"), -- near-black tile
		Color.FromHex("#1d1d1f"), -- ink
	}
	semantic_palette:SetColors{
		red = Color.FromHex("#dc2626"),
		yellow = Color.FromHex("#d97706"),
		blue = primary,
		green = Color.FromHex("#16a34a"),
		purple = Color.FromHex("#7c3aed"),
		brown = Color.FromHex("#8b5e3c"),
	}
	local base_map = semantic_palette:GetBaseMap()
	semantic_palette:SetMap{
		-- Semantic UI tokens
		dashed_underline = Color(0.2, 0.2, 0.2, 0.18),
		property_selection = Color.FromHex("#dbeafe"),
		text_selection = Color.FromHex("#93c5fd"):SetAlpha(0.5),
		underline = primary,
		url_color = primary,
		actual_black = Color(0, 0, 0, 1),
		primary = primary,
		primary_focus = Color.FromHex("#0071e3"),
		primary_on_dark = Color.FromHex("#2997ff"),
		-- Background / surface
		secondary = Color.FromHex("#fafafc"),
		button_color = primary,
		positive = base_map.green,
		neutral = base_map.yellow,
		negative = base_map.red,
		-- Text
		heading = text,
		default = text,
		text = text,
		text_on_accent = Color.FromHex("#f0f0f0"),
		text_on_dark = Color.FromHex("#ffffff"),
		text_on_dark_muted = Color.FromHex("#cccccc"),
		text_disabled = text_muted,
		foreground = text,
		text_background = surface,
		main_background = surface_alt,
		surface = surface,
		surface_alt = surface_alt,
		surface_pearl = Color.FromHex("#fafafc"),
		surface_tile_1 = Color.FromHex("#272729"),
		surface_tile_2 = Color.FromHex("#2a2a2c"),
		surface_tile_3 = Color.FromHex("#252527"),
		surface_black = Color.FromHex("#000000"),
		-- Scrollbars
		scrollbar_track = Color(0, 0, 0, 0.08),
		scrollbar = Color(0.165, 0.165, 0.165, 0.35),
		-- Borders
		border = Color.FromHex("#e0e0e0"),
		divider_soft = Color.FromHex("#f0f0f0"),
		-- Interactive
		invisible = Color(0, 0, 0, 0),
		clickable_disabled = text_muted,
		button_normal = primary,
		-- Icon / chip surfaces
		surface_chip_translucent = Color.FromHex("#d2d2d7"),
	}
	semantic_palette.AdjustmentOptions = {target_contrast = 4.5}
	return semantic_palette
end

function BaseTheme:Initialize()
	if self:GetDefaultFontPath() == "" then
		self:SetDefaultFontPath(fonts.GetDefaultSystemFontPath())
	end

	self:SetPalette(self:CreatePalette())
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

function BaseTheme:GetColorOn(name, surface)
	return self:GetColor(name, {surface = surface})
end

function BaseTheme:GetColor(name, opts)
	name = name or "primary"
	local background

	if type(opts) == "table" then background = opts.surface end

	local palette = self:GetPalette()
	local token = type(name) == "string" and self:GetPaletteBaseToken(name) or name
	local background_token = type(background) == "string" and
		self:GetPaletteBaseToken(background) or
		background

	if token ~= nil and token == background_token then background = nil end

	if
		(
			type(name) ~= "string" or
			self:HasPaletteToken(name)
		) and
		(
			background == nil or
			type(background) ~= "string" or
			self:HasPaletteToken(background)
		)
	then
		return palette:Get(token, background_token)
	end

	return palette and palette:Get("primary")
end

function BaseTheme:ResolveColor(value, fallback)
	if value == nil then value = fallback end

	if type(value) == "string" then return self:GetColor(value) end

	return value
end

function BaseTheme:ResolveSurfaceColor(value, fallback)
	return self:ResolveColor(value, fallback)
end

function BaseTheme:GetSize(name)
	local sizes = self:GetSizes()
	name = name or "default"
	return sizes[name] or sizes.default
end

function BaseTheme:GetPadding(name)
	return self:GetSize(name)
end

function BaseTheme:GetRadius(name)
	local radii = self:GetRadii()
	return radii[name or "M"]
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
	render2d.PushBorderRadius(radius or 0)
	render2d.DrawRect(x, y, w, h)
	render2d.PopBorderRadius()
end

function BaseTheme:DrawRoundRectToken(x, y, w, h, radius, token, alpha)
	self:DrawRoundRect(x, y, w, h, radius, self:GetColor(token), alpha)
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

function BaseTheme:DrawValueField(size, opts)
	opts = opts or {}
	local radius = opts.radius or self:GetRadius("M")
	local fill_alpha = opts.fill_alpha

	if fill_alpha == nil then fill_alpha = 1 end

	local fill

	if opts.fill ~= nil then
		fill = opts.fill
	elseif opts.state == "editing" then
		fill = opts.edit_fill or "surface_alt"
	elseif opts.state == "hovered" then
		fill = opts.hover_fill or self:GetColor("surface_alt"):Copy():SetAlpha(0.45)
	end

	if fill ~= nil then
		self:DrawBox(size, {fill = fill, fill_alpha = fill_alpha, radius = radius})
	end

	if opts.outline ~= false and opts.state == "editing" then
		self:DrawBox(
			size,
			{
				outline = opts.outline_color or "border",
				outline_alpha = opts.outline_alpha or 1,
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
	return self:ResolveColor(color, fallback or "surface")
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

-- Shared icon drawing: pushes color, sets texture, draws lines, pops color
function BaseTheme:DrawIconLines(lines, opts)
	opts = opts or {}
	local thickness = opts.thickness or 1.5
	local color = opts.color or self:GetColor("text")
	render2d.PushColor(color:Unpack())
	render2d.SetTexture(nil)

	for _, line in ipairs(lines) do
		gfx.DrawLine(line[1], line[2], line[3], line[4], thickness)
	end

	render2d.PopColor()
end

function BaseTheme:DrawChevronIcon(size, opts)
	opts = opts or {}
	local icon_size = (opts.size or 10) * 0.6
	local center = size / 2
	local half = icon_size / 2
	local rotation = opts.rotation_degrees or 0
	render2d.PushMatrix()
	render2d.Translatef(center.x, center.y)
	render2d.Rotate(math.rad(rotation))
	self:DrawIconLines(
		{
			{-half * 0.7, -half, half * 0.7, 0},
			{-half * 0.7, half, half * 0.7, 0},
		},
		opts
	)
	render2d.PopMatrix()
end

function BaseTheme:DrawDisclosureIcon(size, opts)
	opts = opts or {}
	return self:DrawChevronIcon(
		size,
		{
			size = opts.size,
			thickness = opts.thickness,
			color = opts.color,
			rotation_degrees = (opts.open_fraction or 0) * 90,
		}
	)
end

function BaseTheme:DrawDropdownIndicatorIcon(size, opts)
	opts = opts or {}
	return self:DrawChevronIcon(
		size,
		{
			size = opts.size or 8,
			thickness = opts.thickness,
			color = opts.color,
			rotation_degrees = 90,
		}
	)
end

function BaseTheme:DrawCloseIcon(size, opts)
	opts = opts or {}
	local icon_size = opts.size or 8
	local thickness = opts.thickness or 1.5
	local color = opts.color or self:GetColor("text")
	local center = size / 2
	local length = icon_size * math.sqrt(2)
	render2d.SetColor(color:Unpack())
	render2d.SetTexture(nil)
	render2d.DrawRect(center.x, center.y, thickness, length, -math.pi / 4, thickness / 2, length / 2)
	render2d.DrawRect(center.x, center.y, thickness, length, math.pi / 4, thickness / 2, length / 2)
end

-- Shared hover animation: animates glow_alpha on hover state change
function BaseTheme:AnimateHover(pnl, anim, state, time)
	if state.hovered ~= anim.last_hovered then
		if not pnl.animation then
			anim.glow_alpha = state.hovered and 1 or 0
			anim.last_hovered = state.hovered
			return
		end

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
			time = time,
		}
		anim.last_hovered = state.hovered
	end
end

function BaseTheme:UpdateButtonAnimations(pnl)
	local state = pnl:GetState()
	state.anim = state.anim or
		{
			glow_alpha = 0,
			press_scale = 0,
			last_hovered = false,
			last_pressed = false,
			last_active = false,
			last_tilting = false,
		}
	local anim = state.anim
	local hovered = state.hovered and not state.disabled
	local pressed = hovered and state.pressed
	self:AnimateHover(pnl, anim, {hovered = hovered}, 0.12)

	if pressed ~= anim.last_pressed then
		if not pnl.animation then
			anim.press_scale = pressed and 1 or 0
			anim.last_pressed = pressed

			if pnl.transform then
				pnl.transform:SetDrawScaleOffset(pressed and (Vec2() + 0.95) or Vec2(1, 1))
			end

			return
		end

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
			to = pressed and (Vec2() + 0.95) or (Vec2(1, 1)),
			interpolation = "inOutSine",
			time = 0.08,
		}
		anim.last_pressed = pressed
	end
end

function BaseTheme:UpdateSliderAnimations(pnl)
	local state = pnl:GetState()
	state.anim = state.anim or
		{
			glow_alpha = 0,
			knob_scale = 1,
			last_hovered = false,
		}
	local anim = state.anim
	self:AnimateHover(pnl, anim, state, 0.15)

	if state.hovered ~= anim.last_hovered then
		if not pnl.animation then
			anim.knob_scale = state.hovered and 1.2 or 1
			return
		end

		pnl.animation:Animate{
			id = "knob_scale",
			get = function()
				return anim.knob_scale
			end,
			set = function(value)
				anim.knob_scale = value
			end,
			to = state.hovered and 1.2 or 1,
			interpolation = {type = "spring", bounce = 0.5, duration = 80},
		}
	end
end

function BaseTheme:UpdateCheckboxAnimations(pnl)
	local state = pnl:GetState()
	state.anim = state.anim or
		{
			glow_alpha = 0,
			check_anim = state.value and 1 or 0,
			last_hovered = state.hovered or false,
			last_value = state.value,
		}
	local anim = state.anim
	self:AnimateHover(pnl, anim, state, 0.15)

	if state.value ~= anim.last_value then
		if not pnl.animation then
			anim.check_anim = state.value and 1 or 0
			anim.last_value = state.value
			return
		end

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
	local anim = state.anim or {
		glow_alpha = 0,
		press_scale = 0,
	}
	local radius = self:GetRadius("M")
	-- Resolve fill token based on state
	local fill_name = self:ResolveButtonFillName(state)
	local fill = self:ResolveButtonFill(state, fill_name)

	-- Draw fill
	if state.mode == "outline" then
		self:DrawRoundRect(0, 0, size.x, size.y, radius, fill, 0.35 + anim.glow_alpha * 0.15)
	elseif state.mode == "text" then
		if fill then self:DrawRoundRect(0, 0, size.x, size.y, radius, fill) end
	else
		self:DrawRoundRect(0, 0, size.x, size.y, radius, fill)
	end

	if state.mode ~= "text" then
		self:DrawButtonOutline(size, radius, state, anim)
	end
end

function BaseTheme:ResolveButtonFillName(state)
	if state.disabled then
		return "clickable_disabled"
	elseif state.mode == "outline" then
		return "surface"
	elseif state.mode == "text" then
		return nil
	else
		return "primary"
	end
end

function BaseTheme:ResolveButtonFill(state, fill_name)
	local accent_override = state.button_color

	if state.mode == "text" then
		if state.disabled then
			return self:GetColor("clickable_disabled")
		elseif state.pressed or state.hovered then
			return (
				accent_override and
				self:GetColor(accent_override) or
				self:GetColor("primary")
			):Copy():SetAlpha(0.06)
		elseif state.active then
			return (
				accent_override and
				self:GetColor(accent_override) or
				self:GetColor("primary")
			):Copy():SetAlpha(0.08)
		else
			return nil
		end
	elseif fill_name == "primary" then
		if accent_override ~= nil then
			if state.disabled then return self:GetColor("clickable_disabled") end

			return self:GetColor(accent_override)
		end

		if state.disabled then
			return self:GetColor("clickable_disabled")
		elseif state.pressed then
			return self:GetColor("primary_focus")
		elseif state.active then
			return self:GetColor("primary_focus")
		elseif state.hovered then
			return self:GetColor("button_normal")
		else
			return self:GetColor("button_color")
		end
	else
		return self:GetColor(fill_name)
	end
end

function BaseTheme:ResolveButtonBackgroundToken(state)
	if state.mode == "text" then return nil end

	if state.disabled then return "clickable_disabled" end

	if state.mode == "outline" then return "surface" end

	if state.button_color ~= nil then return state.button_color end

	if state.pressed or state.active then return "primary_focus" end

	if state.hovered then return "button_normal" end

	return "button_color"
end

function BaseTheme:DrawButtonOutline(size, radius, state, anim)
	local outline_color = state.button_color ~= nil and
		self:GetColor(state.button_color) or
		self:GetColor("primary")

	if state.active and not state.disabled then
		self:DrawRoundOutline(
			0,
			0,
			size.x,
			size.y,
			radius,
			outline_color,
			state.mode == "text" and 0.5 or 0.6,
			1
		)
	else
		self:DrawRoundOutline(0, 0, size.x, size.y, radius, self:GetColor("divider_soft"), 0.55, 1)
	end
end

function BaseTheme:DrawButtonPost(size, state)
	local anim = state.anim or {glow_alpha = 0}

	if not state.hovered or state.disabled then return end

	local radius = self:GetRadius("M")
	self:DrawRoundOutline(
		0,
		0,
		size.x,
		size.y,
		radius,
		state.button_color ~= nil and
			self:GetColor(state.button_color) or
			self:GetColor("primary"),
		anim.glow_alpha * 0.45,
		1
	)
end

function BaseTheme:DrawMenuButton(size, state, opts)
	opts = opts or {}
	local radius = opts.radius or self:GetRadius(XS)
	local fill = self:GetColor("invisible")
	local hovered_alpha = opts.hovered_alpha or 0.1
	local pressed_alpha = opts.pressed_alpha or 0.15
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
	self:DrawBox(
		size,
		{
			fill = fill_color,
			fill_alpha = opts.fill_alpha,
			outline = outline_color or "border",
			outline_alpha = opts.outline_alpha,
			radius = opts.radius or 0,
			thickness = opts.thickness or 1,
		}
	)
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
	local color = self:GetColor(opts.color or "primary")
	local thickness = opts.thickness or 2
	local w = math.max(1, size.x)
	local h = math.max(1, size.y)
	self:SetRenderColor(color, opts.alpha)
	render2d.SetTexture(nil)

	if opts.source then
		self:DrawRoundOutline(0, 0, w, h, 0, color, opts.alpha, 1)
	end

	if opts.position == "inside" then
		self:DrawRoundOutline(0, 0, w, h, 0, color, opts.alpha, 2)
	elseif opts.position == "before" then
		render2d.DrawRect(0, 0, w, thickness)
	elseif opts.position == "after" then
		render2d.DrawRect(0, math.max(0, h - thickness), w, thickness)
	end
end

function BaseTheme:DrawPreviewTileFrame(size, opts)
	opts = opts or {}
	local radius = opts.radius or self:GetRadius("L")
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

function BaseTheme:DrawSurface(size, color, radius)
	self:DrawPanelFill(size, color or "surface", 1, radius)
end

function BaseTheme:DrawTrack(x, y, w, h, fill_extent, radius, track_color, accent_color)
	self:DrawRoundRect(x, y, w, h, radius, track_color)

	if h <= w then
		self:DrawRoundRect(x, y, fill_extent, h, radius, accent_color)
	else
		self:DrawRoundRect(x, y, w, fill_extent, radius, accent_color)
	end
end

function BaseTheme:DrawSlider(size, state)
	local anim = state.anim or {
		glow_alpha = 0,
		knob_scale = 1,
	}
	local knob_w = self:GetSize("M")
	local knob_h = self:GetSize("M")
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
		self:DrawTrack(
			track_x,
			knob_h / 2,
			track_w,
			size.y - knob_h,
			normalized * (size.y - knob_h),
			track_w / 2,
			track,
			accent
		)
		knob_x = (size.x - knob_w) / 2
		knob_y = normalized * (size.y - knob_h)
	else
		local normalized = (value - min_value) / (max_value - min_value)
		local track_h = self:GetSize("XXS")
		local track_y = (size.y - track_h) / 2
		self:DrawTrack(
			knob_w / 2,
			track_y,
			size.x - knob_w,
			track_h,
			normalized * (size.x - knob_w),
			track_h / 2,
			track,
			accent
		)
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

-- Shared checkable control drawing: outer shape + outline + inner fill when checked
-- inner_draw: function(draw_x, draw_y, draw_size, draw_radius, color, alpha) -> draws the inner checked shape
function BaseTheme:DrawCheckable(size, state, opts)
	local anim = state.anim or
		{
			glow_alpha = 0,
			check_anim = state.value and 1 or 0,
			last_hovered = state.hovered or false,
			last_value = state.value,
		}
	local box_size = self:GetSize("M")
	local x = 0
	local y = (size.y - box_size) / 2
	local radius = opts.radius or self:GetRadius(XS)
	self:DrawRoundRect(x, y, box_size, box_size, radius, self:GetColor("surface"))
	self:DrawRoundOutline(x, y, box_size, box_size, radius, self:GetColor("border"), 1, 1)

	if anim.check_anim > 0.01 then
		opts.inner_draw(x, y, box_size, radius, anim.check_anim)
	end
end

function BaseTheme:DrawCheckbox(size, state)
	self:DrawCheckable(
		size,
		state,
		{
			radius = self:GetRadius(XS),
			inner_draw = function(x, y, box_size, radius, anim_val)
				local inset = 3 + (1 - anim_val) * 3
				self:DrawRoundRect(
					x + inset,
					y + inset,
					box_size - inset * 2,
					box_size - inset * 2,
					2,
					self:GetColor("primary"),
					anim_val
				)
			end,
		}
	)
end

function BaseTheme:DrawButtonRadio(size, state)
	self:DrawCheckable(
		size,
		state,
		{
			radius = math.floor(self:GetSize("M") / 2),
			inner_draw = function(x, y, box_size, radius, anim_val)
				local dot = box_size * 0.42 * anim_val
				local dot_x = x + box_size / 2 - dot / 2
				local dot_y = y + box_size / 2 - dot / 2
				self:DrawRoundRect(dot_x, dot_y, dot, dot, math.floor(dot / 2), self:GetColor("primary"))
			end,
		}
	)
end

function BaseTheme:DrawFrame(size, emphasis)
	local radius = self:GetRadius("M")
	self:DrawBox(size, {fill = "surface", fill_alpha = 1, radius = radius})
end

function BaseTheme:DrawFramePost(size)
	self:DrawBox(
		size,
		{
			outline = "border",
			outline_alpha = 1,
			radius = self:GetRadius("M"),
			thickness = 1,
		}
	)
end

function BaseTheme:DrawHeader(size)
	self:DrawBox(size, {fill = "surface_alt", fill_alpha = 1, radius = self:GetRadius("none")})
	self:SetRenderColor(self:GetColor("border"), 1)
	render2d.SetTexture(nil)
	render2d.DrawRect(0, math.max(0, size.y - 1), size.x, 1)
end

function BaseTheme:DrawProgressBar(size, state, color)
	local value = math.clamp(state.value or 0, 0, 1)
	color = self:ResolveSurfaceFill(color, "primary")
	local radius = math.min(math.floor(size.y / 2), self:GetRadius("full"))
	self:DrawBox(
		size,
		{
			fill = "surface_alt",
			outline = "border",
			outline_alpha = 1,
			radius = radius,
			thickness = 1,
		}
	)
	self:DrawRoundRect(0, 0, size.x * value, size.y, radius, color)
end

function BaseTheme:DrawDivider(size)
	self:DrawLine(0, 1, size, "auto")
end

function BaseTheme:DrawMenuContainer(size)
	self:DrawBox(
		size,
		{
			fill = "surface",
			fill_alpha = 1,
			radius = self:GetRadius(XS),
			outline = "border",
			outline_alpha = 1,
			thickness = 1,
		}
	)
end

-- Draw a 1px line: color token, alpha, size, orientation ("auto", "horizontal", "vertical")
function BaseTheme:DrawLine(color_token, alpha, size, orientation)
	if color_token == nil or color_token == 0 then color_token = "border" end

	self:SetRenderColor(self:GetColor(color_token), alpha)
	render2d.SetTexture(nil)
	local horiz = orientation == "auto" and size.x > size.y or orientation == "horizontal"

	if horiz then
		render2d.DrawRect(0, math.floor(size.y / 2), size.x, 1)
	else
		render2d.DrawRect(math.floor(size.x / 2), 0, 1, size.y)
	end
end

function BaseTheme:Draw(pnl)
	local role = pnl.GetState and pnl:GetState("theme_role")

	if role == "property_value" then
		local state_name = pnl:GetState("editing") and
			"editing" or
			(
				pnl:GetState("hovered") and
				pnl:GetState("surface_visible") and
				"hovered" or
				nil
			)
		return self:DrawValueField(
			pnl.transform:GetTotalSize(),
			{
				state = state_name,
				fill = state_name and pnl:GetState("surface_color") or nil,
				radius = self:GetRadius("L"),
			}
		)
	elseif role == "property_preview" then
		return self:DrawPropertyPreview(
			pnl.transform:GetTotalSize(),
			{
				fill = pnl:GetState("preview_fill"),
				fill_alpha = pnl:GetState("preview_fill_alpha"),
				outline = pnl:GetState("preview_outline"),
				outline_alpha = pnl:GetState("preview_outline_alpha"),
				radius = pnl:GetState("preview_radius") or 0,
				thickness = pnl:GetState("preview_thickness") or 1,
			}
		)
	elseif role == "tree_toggle" then
		return self:DrawTreeToggle(pnl.transform:GetSize(), pnl:GetState("tree_meta"), pnl:GetState("tree_opts") or {})
	elseif role == "tree_guides" then
		return self:DrawTreeGuideLines(pnl.transform:GetSize(), pnl:GetState("tree_meta"), pnl:GetState("tree_opts") or {})
	elseif role == "tree_label" then
		local size = pnl.transform:GetSize()

		if pnl:GetState("selected") then
			return self:DrawSelectionFill(size, pnl:GetState("selected_color") or "primary")
		elseif pnl:GetState("hovered") then
			return self:DrawSelectionFill(size, pnl:GetState("hover_color"))
		end

		return
	elseif role == "asset_preview_tile" then
		local size = pnl.transform:GetTotalSize()
		self:DrawPreviewTileFrame(size, pnl:GetState("preview_frame_opts") or {})
		local secondary = pnl:GetState("preview_frame_secondary_opts")

		if secondary then self:DrawPreviewTileFrame(size, secondary) end

		return
	end

	if pnl.Name == "checkbox" then
		return self:DrawCheckbox(pnl.transform:GetSize(), pnl:GetState())
	elseif pnl.Name == "radio_button" then
		return self:DrawButtonRadio(pnl.transform:GetSize(), pnl:GetState())
	elseif pnl.Name == "clickable" then
		return self:DrawButton(pnl.transform:GetTotalSize(), pnl:GetState())
	elseif pnl.Name == "slider" then
		return self:DrawSlider(pnl.transform:GetSize(), pnl:GetState())
	elseif pnl.Name == "progress_bar" then
		local state = pnl:GetState()
		return self:DrawProgressBar(pnl.transform:GetSize(), state, state.color)
	elseif pnl.Name == "frame" then
		return self:DrawFrame(pnl.transform:GetTotalSize(), pnl:GetState("emphasis") or 1)
	elseif pnl.Name == "WindowHeader" then
		return self:DrawHeader(pnl.transform:GetSize())
	elseif pnl.Name == "WindowContent" or pnl.Name == "TooltipOverlay" then
		return self:DrawFrame(pnl.transform:GetTotalSize(), pnl:GetState("emphasis") or 0)
	elseif pnl.Name == "text_edit" then
		return self:DrawSurface(pnl.transform:GetTotalSize(), pnl:GetState("panel_color"), self:GetRadius("M"))
	elseif pnl.Name == "MenuContainer" then
		return self:DrawMenuContainer(pnl.transform:GetSize())
	elseif pnl.Name == "MenuSpacer" or pnl.Name == "splitter" then
		return self:DrawDivider(pnl.transform:GetSize())
	elseif pnl.Name == "PropertyLabelRow" or pnl.Name == "PropertyEditorRow" then
		return self:DrawPropertyRow(
			pnl.transform:GetSize(),
			{
				selected = pnl:GetState("selected"),
				alternate = pnl:GetState("alternate"),
				hovered = pnl:GetState("hovered"),
			}
		)
	elseif pnl.Name == "PropertyEditorDivider" then
		return self:DrawDivider(pnl.transform:GetSize())
	elseif pnl.Name == "PropertyObjectValue" then
		return self:DrawPropertyPreview(pnl.transform:GetSize(), {fill = "surface_alt", outline = "border"})
	elseif pnl.Name == "PropertyObjectActionButton" then
		return self:DrawPropertyPreview(
			pnl.transform:GetSize(),
			{
				fill = self:GetColor("actual_black"):Copy():SetAlpha(1),
				outline = "border",
			}
		)
	elseif pnl.Name == "MenuBarButton" then
		return self:DrawMenuButton(
			pnl.transform:GetSize(),
			pnl:GetState(),
			{hovered_alpha = 0.18, pressed_alpha = 0.28, radius = self:GetRadius(XS)}
		)
	elseif pnl.Name == "ContextMenuItem" then
		return self:DrawMenuButton(
			pnl.transform:GetSize(),
			pnl:GetState(),
			{hovered_alpha = 0.12, pressed_alpha = 0.18, radius = self:GetRadius(XS)}
		)
	elseif pnl.Name == "svg" and pnl:GetState("background_color") ~= nil then
		return self:DrawSurface(pnl.transform:GetTotalSize(), pnl:GetState("background_color"), 0)
	elseif type(pnl.Name) == "string" and pnl.Name:find("^scrollbar_track_") then
		return self:DrawSurface(
			pnl.transform:GetTotalSize(),
			pnl:GetState("color") or "scrollbar_track",
			self:GetRadius("M")
		)
	elseif type(pnl.Name) == "string" and pnl.Name:find("^scrollbar_handle_") then
		return self:DrawSurface(
			pnl.transform:GetTotalSize(),
			pnl:GetState("color") or "scrollbar",
			self:GetRadius("M")
		)
	end
end

function BaseTheme:DrawPost(pnl)
	local role = pnl.GetState and pnl:GetState("theme_role")

	if role == "tree_drop_indicator" then
		return self:DrawDropIndicator(pnl.transform:GetSize(), pnl:GetState("drop_indicator_opts") or {})
	end

	if pnl.Name == "clickable" then
		return self:DrawButtonPost(pnl.transform:GetTotalSize(), pnl:GetState())
	elseif
		pnl.Name == "frame" or
		pnl.Name == "WindowContent" or
		pnl.Name == "TooltipOverlay"
	then
		return self:DrawFramePost(pnl.transform:GetTotalSize(), pnl:GetState("emphasis") or 1)
	elseif pnl.Name == "text_edit" and pnl:GetState("editable") then
		return self:DrawFramePost(pnl.transform:GetTotalSize())
	end
end

function BaseTheme:UpdateAnimations(pnl)
	if pnl.Name == "checkbox" then return self:UpdateCheckboxAnimations(pnl) end

	if pnl.Name == "radio_button" then return self:UpdateCheckboxAnimations(pnl) end

	if pnl.Name == "clickable" then return self:UpdateButtonAnimations(pnl) end

	if pnl.Name == "slider" then return self:UpdateSliderAnimations(pnl) end
end

return BaseTheme:Register()
