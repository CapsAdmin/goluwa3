local Color = import("goluwa/structs/color.lua")
local ColorPalette = import("goluwa/palette.lua")
local Rect = import("goluwa/structs/rect.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local objects = import("goluwa/objects/objects.lua")
local SVG = import("goluwa/render2d/svg.lua")
local BaseTheme = objects.CreateTemplate("ui_theme_base")
BaseTheme.Name = "base"
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
		M = 16,
		L = 24,
		XL = 32,
		XXL = 48,
		default = 12,
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

do
	local FONT_SIZE_ORDER = {"XS", "S", "M", "L", "XL", "XXL", "XXXL"}

	function BaseTheme:GetFontSizesList()
		local list = {}
		local font_sizes = self:GetFontSizes()

		for _, name in ipairs(FONT_SIZE_ORDER) do
			if font_sizes[name] then table.insert(list, name) end
		end

		return list
	end
end

do
	local FONT_NAME_ORDER = {"heading", "body_weak", "body", "body_strong"}

	function BaseTheme:GetFontNamesList()
		local list = {}
		local font_styles = self:GetFontStyles()

		for _, name in ipairs(FONT_NAME_ORDER) do
			if font_styles[name] then table.insert(list, name) end
		end

		return list
	end
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
		surface_alt,
		Color.FromHex("#272729"), -- near-black tile
		text,
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
		-- Accent / interactive
		primary = primary,
		primary_focus = Color.FromHex("#0071e3"),
		button_color = primary,
		button_normal = primary,
		clickable_disabled = text_muted,
		property_selection = Color.FromHex("#dbeafe"),
		text_selection = Color.FromHex("#93c5fd"):SetAlpha(0.5),
		-- Semantic
		positive = base_map.green,
		neutral = base_map.yellow,
		negative = base_map.red,
		-- Text
		text = text,
		text_on_accent = Color.FromHex("#f0f0f0"),
		text_on_dark = Color.FromHex("#ffffff"),
		text_disabled = text_muted,
		-- Surfaces
		surface = surface,
		surface_alt = surface_alt,
		surface_tile_1 = Color.FromHex("#272729"),
		actual_black = Color(0, 0, 0, 1),
		-- Scrollbars
		scrollbar_track = Color(0, 0, 0, 0.08),
		scrollbar = Color(0.165, 0.165, 0.165, 0.35),
		-- Borders
		border = Color.FromHex("#e0e0e0"),
		invisible = Color(0, 0, 0, 0),
	}
	semantic_palette.AdjustmentOptions = {target_contrast = 4.5}
	return semantic_palette
end

function BaseTheme:Initialize()
	self:AddGlobalEvent("OnEntitySetProperty", {func_name = "OnEntitySetProperty"})
	self:AddGlobalEvent("OnEntityStateChanged", {func_name = "OnEntityStateChanged"})

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
	local token = type(name) == "string" and name or name
	local background_token = type(background) == "string" and background or background
	local base_token = type(name) == "string" and self:GetPaletteBaseToken(name) or name
	local base_background_token = type(background) == "string" and
		self:GetPaletteBaseToken(background) or
		background

	if base_token ~= nil and base_token == base_background_token then
		background_token = nil
	end

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

	return palette:Get("primary")
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

function BaseTheme:ResolveSize(value)
	if type(value) == "string" then return self:GetSize(value) end

	return value
end

function BaseTheme:GetInputHeight(font_size_name)
	return self:ResolveFontSize(font_size_name or "M") + self:GetPadding("S") * 2
end

function BaseTheme:GetScrollbarWidth()
	return self:GetSize("XXS")
end

function BaseTheme:GetScrollbarMargin()
	return self:GetSize("XXS")
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
	render2d.PushOutlineWidth(-(thickness or self:GetSize("line")))
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
			opts.thickness or self:GetSize("line")
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
		opts.thickness or self:GetSize("line")
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
				thickness = opts.thickness or self:GetSize("line"),
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
		return self:DrawSelectionFill(size, opts.hover_color or self:GetHoverTint(nil, 0.08))
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
			thickness = opts.thickness or self:GetSize("line"),
		}
	)
end

function BaseTheme:ResolveSurfaceFill(color, fallback)
	return self:ResolveColor(color, fallback or "surface")
end

function BaseTheme:GetAccentTint(alpha)
	return self:GetColor("primary"):Copy():SetAlpha(alpha)
end

function BaseTheme:GetHoverTint(color, alpha)
	return self:ResolveColor(color, "primary"):Copy():SetAlpha(alpha or 0.08)
end

do -- icons
	function BaseTheme:DrawIcon(name, size, opts)
		if name == "disclosure" then
			return self:DrawDisclosureIcon(size, opts)
		elseif name == "dropdown_indicator" then
			return self:DrawDropdownIndicatorIcon(size, opts)
		elseif name == "close" then
			return self:DrawCloseIcon(size, opts)
		end
	end

	local icon_svg_cache = {}
	local icons = {
		chevron = [[<svg viewBox="0 0 16 16"><path d="M5.2 2.2L10.8 8l-5.6 5.8l1.4 1.3L13.4 8L6.6.9z"/></svg>]],
		plus = [[<svg viewBox="0 0 16 16"><path d="M7 3h2v4h4v2H9v4H7V9H3V7h4z"/></svg>]],
		minus = [[<svg viewBox="0 0 16 16"><path d="M3 7h10v2H3z"/></svg>]],
		close = [[<svg viewBox="0 0 16 16"><path d="M3.3 1.9L8 6.6l4.7-4.7l1.4 1.4L9.4 8l4.7 4.7l-1.4 1.4L8 9.4l-4.7 4.7l-1.4-1.4L6.6 8L1.9 3.3z"/></svg>]],
	}

	local function get_cached_icon_svg(name)
		local cached = icon_svg_cache[name]

		if cached then return cached end

		if not icons[name] then return nil end

		icon_svg_cache[name] = SVG.New(icons[name], {TextureSize = 16, Mode = "msdf"})
		return icon_svg_cache[name]
	end

	function BaseTheme:ResolveIconDrawSize(size, requested_size, inset)
		inset = inset or self:GetSize("XXXS")
		local available = math.max(1, math.min(size.x, size.y) - inset * 2)
		local base = requested_size or self:GetSize("M")
		return math.max(1, math.min(base, available))
	end

	function BaseTheme:DrawSVGIcon(name, size, opts)
		opts = opts or {}
		local svg = get_cached_icon_svg(name)

		if not svg or svg:GetStatus() ~= "loaded" then return end

		local target_size = self:ResolveIconDrawSize(size, opts.size, opts.inset)
		local color = opts.color or self:GetColor("text")
		render2d.PushMatrixf(0, 0, target_size, target_size, math.rad(opts.rotation_degrees or 0))
		render2d.PushColor(color:Unpack())
		svg:Draw()
		render2d.PopColor()
		render2d.PopMatrix()
	end

	function BaseTheme:DrawChevronIcon(size, opts)
		opts = opts or {}
		return self:DrawSVGIcon(
			"chevron",
			size,
			{
				size = opts.size or self:GetSize("M"),
				inset = opts.inset or self:GetSize("line"),
				color = opts.color,
				rotation_degrees = opts.rotation_degrees,
			}
		)
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
				size = opts.size or self:GetSize("M"),
				inset = opts.inset or self:GetSize("line"),
				thickness = opts.thickness,
				color = opts.color,
				rotation_degrees = 90,
			}
		)
	end

	function BaseTheme:DrawCloseIcon(size, opts)
		opts = opts or {}
		return self:DrawSVGIcon(
			"close",
			size,
			{
				size = opts.size or self:GetSize("M"),
				inset = opts.inset or self:GetSize("line"),
				color = opts.color,
			}
		)
	end
end

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

do
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
					pnl.transform:SetDrawScaleOffset(pressed and (Vec2() + 0.99) or Vec2(1, 1))
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
				to = pressed and (Vec2() + 0.99) or (Vec2(1, 1)),
				interpolation = "inOutSine",
				time = 0.08,
			}
			anim.last_pressed = pressed
		end
	end

	do
		function BaseTheme:ResolveButtonStyleContext(state)
			local accent_token = state.button_color ~= nil and state.button_color or "button_color"
			local accent_fill_token = state.button_color ~= nil and state.button_color or "primary"
			local background_token
			local foreground_token
			local menu_fill = self:GetColor("invisible")
			local menu_outline_token
			local menu_outline_alpha
			local outline_token = "border"
			local outline_alpha = 1
			local overlay_token
			local overlay_alpha
			local post_outline_token
			local post_outline_alpha

			if state.mode == "text" then
				if state.hovered then background_token = accent_fill_token end
			elseif state.mode ~= "menu" then
				if state.disabled then
					background_token = "clickable_disabled"
				elseif state.mode == "outline" then
					background_token = "surface"
				elseif state.button_color ~= nil then
					background_token = state.button_color
				elseif state.pressed or state.active then
					background_token = "primary_focus"
				elseif state.hovered then
					background_token = "button_normal"
				else
					background_token = "button_color"
				end
			end

			if state.disabled then
				foreground_token = "text_disabled"
			elseif state.mode == "text" or state.mode == "outline" then
				if state.button_color ~= nil then
					if state.hovered or state.pressed or state.active then
						foreground_token = "text_on_accent"
					else
						foreground_token = state.button_color
					end
				else
					foreground_token = state.hovered and "text_on_accent" or "text"
				end
			elseif state.mode == "filled" then
				foreground_token = "text_on_accent"
			else
				foreground_token = "text"
			end

			if state.mode == "menu" then
				if state.disabled then
					menu_fill = self:GetColor("invisible")
				elseif state.pressed then
					menu_fill = self:GetColor("primary"):Copy():SetAlpha(0.15)
				elseif state.selected then
					menu_fill = self:GetColor(state.selected_color or "property_selection")
				elseif state.active or state.hovered then
					menu_fill = self:GetColor("primary"):Copy():SetAlpha(0.1)
				end

				if (state.active or state.selected) and not state.disabled then
					menu_outline_token = "border"
					menu_outline_alpha = 0.7
				end
			end

			if state.mode == "outline" then
				outline_token = "border"
				outline_alpha = state.disabled and 0.5 or 1

				if state.disabled then
					overlay_token = "clickable_disabled"
					overlay_alpha = 0.12
				elseif state.pressed or state.hovered or state.active then
					overlay_token = accent_token
					overlay_alpha = 0.12
				end
			elseif state.active and not state.disabled and state.mode ~= "menu" then
				outline_token = "border"
				outline_alpha = state.mode == "text" and 0.5 or 0.6
			end

			if
				not state.disabled and
				state.hovered and
				state.mode ~= "outline" and
				state.mode ~= "text" and
				state.mode ~= "menu"
			then
				post_outline_token = accent_fill_token
				post_outline_alpha = 0.45
			end

			return {
				accent_token = accent_token,
				accent_fill_token = accent_fill_token,
				background_token = background_token,
				foreground_token = foreground_token,
				menu_fill = menu_fill,
				menu_outline_token = menu_outline_token,
				menu_outline_alpha = menu_outline_alpha,
				outline_token = outline_token,
				outline_alpha = outline_alpha,
				overlay_token = overlay_token,
				overlay_alpha = overlay_alpha,
				post_outline_token = post_outline_token,
				post_outline_alpha = post_outline_alpha,
			}
		end

		function BaseTheme:DrawFilledButton(size, state)
			local anim = state.anim or {
				glow_alpha = 0,
				press_scale = 0,
			}
			local radius = self:GetRadius("M")
			local context = self:ResolveButtonStyleContext(state)
			local fill = self:GetColor(context.background_token)
			self:DrawRoundRect(0, 0, size.x, size.y, radius, fill)
			self:DrawRoundOutline(
				0,
				0,
				size.x,
				size.y,
				radius,
				self:GetColor(context.outline_token),
				context.outline_alpha,
				self:GetSize("line")
			)
		end

		function BaseTheme:DrawTextButton(size, state)
			local radius = self:GetRadius("M")
			local context = self:ResolveButtonStyleContext(state)
			local fill = context.background_token and self:GetColor(context.background_token) or nil

			if fill then self:DrawRoundRect(0, 0, size.x, size.y, radius, fill) end
		end

		function BaseTheme:DrawOutlineButton(size, state)
			local radius = self:GetRadius("M")
			local context = self:ResolveButtonStyleContext(state)
			local outline_color = context.overlay_token and self:GetColor(context.overlay_token) or nil

			if outline_color then
				self:DrawRoundRect(0, 0, size.x, size.y, radius, outline_color, context.overlay_alpha)
			end

			self:DrawRoundOutline(
				0,
				0,
				size.x,
				size.y,
				radius,
				self:GetColor(context.outline_token),
				context.outline_alpha,
				self:GetSize("line")
			)
		end

		function BaseTheme:DrawButton(size, state)
			if state.mode == "menu" then
				return self:DrawMenuButton(size, state)
			elseif state.mode == "outline" then
				return self:DrawOutlineButton(size, state)
			elseif state.mode == "text" then
				return self:DrawTextButton(size, state)
			end

			return self:DrawFilledButton(size, state)
		end
	end

	function BaseTheme:DrawButtonPost(size, state)
		local anim = state.anim or {glow_alpha = 0}
		local context = self:ResolveButtonStyleContext(state)

		if not context.post_outline_token or not context.post_outline_alpha then
			return
		end

		local radius = self:GetRadius("M")
		self:DrawRoundOutline(
			0,
			0,
			size.x,
			size.y,
			radius,
			self:GetColor(context.post_outline_token),
			anim.glow_alpha * context.post_outline_alpha,
			self:GetSize("line")
		)
	end

	function BaseTheme:DrawMenuButton(size, state, opts)
		opts = opts or {}
		local radius = opts.radius or self:GetRadius("XS")
		local context = self:ResolveButtonStyleContext(state)
		local fill = context.menu_fill or self:GetColor("invisible")
		self:DrawBox(size, {fill = fill, radius = radius})

		if context.menu_outline_token then
			self:DrawBox(
				size,
				{
					outline = context.menu_outline_token,
					radius = radius,
					outline_alpha = context.menu_outline_alpha,
				}
			)
		end
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
			thickness = thickness or self:GetSize("line"),
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
			thickness = opts.thickness or self:GetSize("line"),
		}
	)
end

function BaseTheme:DrawSelectionFill(size, color, alpha)
	self:DrawPanelFill(size, self:ResolveColor(color, color or "primary"), alpha, 0)
end

function BaseTheme:DrawTreeGuideLines(size, meta, opts)
	opts = opts or {}
	local line = self:GetSize("line")
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
			render2d.DrawRect(x, 0, line, size.y)
		end
	end

	if meta.level > 0 then render2d.DrawRect(center_x, 0, line, center_y + 1) end

	if not meta.is_last then
		render2d.DrawRect(center_x, center_y, line, size.y - center_y)
	end

	render2d.DrawRect(line_start_x, center_y, math.max(1, size.x - line_start_x), line)
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
			thickness = self:GetSize("line"),
		}
	)
	self:DrawRoundRect(box_x, box_y, box_size, box_size, 0, self:GetColor(opts.box_fill or "surface"))
	render2d.PushMatrix()
	render2d.Translatef(box_x, box_y)
	self:DrawSVGIcon(
		opts.expanded and "minus" or "plus",
		Vec2(box_size, box_size),
		{
			size = opts.icon_size or self:GetSize("M"),
			inset = opts.icon_inset or self:GetSize("line"),
			color = self:GetColor(opts.glyph_color or "text"):Copy():SetAlpha(opts.glyph_alpha or 1),
		}
	)
	render2d.PopMatrix()
	return center_x, center_y
end

function BaseTheme:DrawSharedInstanceMarker(size, color)
	self:SetRenderColor(self:ResolveColor(color, "primary"), 1)
	render2d.SetTexture(nil)
	local line = self:GetSize("line")
	local inset = self:GetSize("XXXS")
	render2d.DrawRect(inset, math.floor(size.y * 0.5) - line, math.max(1, size.x - inset * 2), line * 2)
	render2d.DrawRect(math.floor(size.x * 0.5) - line, inset, line * 2, math.max(1, size.y - inset * 2))
end

function BaseTheme:DrawDropIndicator(size, opts)
	opts = opts or {}
	local color = self:GetColor(opts.color or "primary")
	local thickness = opts.thickness or self:GetSize("XXXS")
	local w = math.max(1, size.x)
	local h = math.max(1, size.y)
	self:SetRenderColor(color, opts.alpha)
	render2d.SetTexture(nil)

	if opts.source then
		self:DrawRoundOutline(0, 0, w, h, 0, color, opts.alpha, self:GetSize("line"))
	end

	if opts.position == "inside" then
		self:DrawRoundOutline(0, 0, w, h, 0, color, opts.alpha, self:GetSize("XXXS"))
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
			thickness = opts.thickness or self:GetSize("line"),
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
				thickness = opts.thickness or self:GetSize("line"),
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
		local radius = self:GetRadius("L")
		self:DrawRoundRect(0, 0, size.x, size.y, radius, self:GetColor("surface"))
		self:DrawRoundOutline(0, 0, size.x, size.y, radius, border, 1, self:GetSize("line"))
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
		self:GetSize("line")
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
			self:GetSize("line")
		)
	end
end

-- Shared checkable control drawing: outer shape + outline + inner fill when checked
-- inner_draw: function(theme, draw_x, draw_y, draw_size, draw_radius, alpha) -> draws the inner checked shape
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
	local radius = opts.radius or self:GetRadius("XS")
	self:DrawRoundRect(x, y, box_size, box_size, radius, self:GetColor("surface"))
	self:DrawRoundOutline(
		x,
		y,
		box_size,
		box_size,
		radius,
		self:GetColor("border"),
		1,
		self:GetSize("line")
	)

	if anim.check_anim > 0.01 then
		opts.inner_draw(self, x, y, box_size, radius, anim.check_anim)
	end
end

do
	local function draw_checkbox_inner(theme, x, y, box_size, radius, anim_val)
		local inset = theme:GetSize("XXS") + (1 - anim_val) * theme:GetSize("XXXS")
		theme:DrawRoundRect(
			x + inset,
			y + inset,
			box_size - inset * 2,
			box_size - inset * 2,
			theme:GetRadius("XS"),
			theme:GetColor("primary"),
			anim_val
		)
	end

	function BaseTheme:DrawCheckbox(size, state)
		self:DrawCheckable(
			size,
			state,
			{
				radius = self:GetRadius("XS"),
				inner_draw = draw_checkbox_inner,
			}
		)
	end

	local function draw_button_radio_inner(theme, x, y, box_size, radius, anim_val)
		local dot = box_size * 0.42 * anim_val
		local dot_x = x + box_size / 2 - dot / 2
		local dot_y = y + box_size / 2 - dot / 2
		theme:DrawRoundRect(dot_x, dot_y, dot, dot, math.floor(dot / 2), theme:GetColor("primary"))
	end

	function BaseTheme:DrawButtonRadio(size, state)
		self:DrawCheckable(
			size,
			state,
			{
				radius = math.floor(self:GetSize("M") / 2),
				inner_draw = draw_button_radio_inner,
			}
		)
	end
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
			thickness = self:GetSize("line"),
		}
	)
end

function BaseTheme:DrawHeader(size)
	self:DrawBox(size, {fill = "surface_alt", fill_alpha = 1, radius = self:GetRadius("none")})
	local line = self:GetSize("line")
	self:SetRenderColor(self:GetColor("border"), 1)
	render2d.SetTexture(nil)
	render2d.DrawRect(0, math.max(0, size.y - line), size.x, line)
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
			thickness = self:GetSize("line"),
		}
	)
	self:DrawRoundRect(0, 0, size.x * value, size.y, radius, color)
end

function BaseTheme:DrawDivider(size)
	self:DrawLine(0, 1, size, "auto")
end

function BaseTheme:DrawMenuSpacer(size, vertical)
	self:DrawLine(0, 1, size, vertical and "vertical" or "horizontal")
end

function BaseTheme:DrawMenuContainer(size)
	self:DrawBox(
		size,
		{
			fill = "surface",
			fill_alpha = 1,
			radius = self:GetRadius("XS"),
			outline = "border",
			outline_alpha = 1,
			thickness = self:GetSize("line"),
		}
	)
end

-- Draw a 1px line: color token, alpha, size, orientation ("auto", "horizontal", "vertical")
function BaseTheme:DrawLine(color_token, alpha, size, orientation)
	if color_token == nil or color_token == 0 then color_token = "border" end

	self:SetRenderColor(self:GetColor(color_token), alpha)
	render2d.SetTexture(nil)
	local line = self:GetSize("line")
	local horiz = orientation == "auto" and size.x > size.y or orientation == "horizontal"

	if horiz then
		render2d.DrawRect(0, math.floor(size.y / 2), size.x, line)
	else
		render2d.DrawRect(math.floor(size.x / 2), 0, line, size.y)
	end
end

function BaseTheme:Draw(pnl)
	local role = pnl.GetState and pnl:GetState("theme_role")

	if role == "property_value" then
		local state_name = pnl:GetState("editing") and
			"editing" or
			(
				pnl:GetState("hovered") and
				"hovered" or
				nil
			)
		return self:DrawValueField(
			pnl.transform:GetTotalSize(),
			{
				state = state_name,
				hover_fill = pnl:GetState("hover_fill"),
				edit_fill = pnl:GetState("edit_fill"),
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
				thickness = pnl:GetState("preview_thickness") or self:GetSize("line"),
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
			return self:DrawSelectionFill(size, pnl:GetState("hover_color") or self:GetHoverTint())
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
		return self:DrawFrame(pnl.transform:GetTotalSize(), self:GetEmphasis(pnl))
	elseif pnl.Name == "WindowHeader" then
		return self:DrawHeader(pnl.transform:GetSize(), self:GetEmphasis(pnl))
	elseif pnl.Name == "WindowContent" or pnl.Name == "TooltipOverlay" then
		return self:DrawFrame(pnl.transform:GetTotalSize(), self:GetEmphasis(pnl))
	elseif pnl.Name == "text_edit" then
		return self:DrawSurface(pnl.transform:GetTotalSize(), pnl:GetState("panel_color"), self:GetRadius("M"))
	elseif pnl.Name == "MenuContainer" then
		return self:DrawMenuContainer(pnl.transform:GetSize())
	elseif pnl.Name == "MenuSpacer" then
		return self:DrawMenuSpacer(pnl.transform:GetSize(), pnl:GetState("vertical"))
	elseif pnl.Name == "splitter" then
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
		return self:DrawFramePost(pnl.transform:GetTotalSize(), self:GetEmphasis(pnl))
	elseif pnl.Name == "text_edit" and pnl:GetState("editable") then
		return self:DrawFramePost(pnl.transform:GetTotalSize(), self:GetEmphasis(pnl))
	end
end

-- Decorative emphasis levels, assigned by role. Frame manages its own
-- "emphasis" state (defaults to 0, set via the Emphasis prop).
local ROLE_EMPHASIS = {
	WindowHeader = 3,
	WindowContent = 3,
	TooltipOverlay = 2,
	text_edit = 1,
}

function BaseTheme:GetEmphasis(pnl)
	local override = pnl:GetState("emphasis")

	if override ~= nil then return override end

	return ROLE_EMPHASIS[pnl.Name] or 0
end

function BaseTheme:OnEntityStateChanged(pnl, key, val)
	self:UpdateAnimations(pnl)
end

function BaseTheme:UpdateAnimations(pnl)
	if pnl.Name == "checkbox" then return self:UpdateCheckboxAnimations(pnl) end

	if pnl.Name == "radio_button" then return self:UpdateCheckboxAnimations(pnl) end

	if pnl.Name == "clickable" then return self:UpdateButtonAnimations(pnl) end

	if pnl.Name == "slider" then return self:UpdateSliderAnimations(pnl) end
end

function BaseTheme:OnEntitySetProperty(obj, key, val)
	if key == "Padding" then
		if type(val) == "string" then return Rect() + self:GetPadding(val) end
	elseif key == "Color" then
		if type(val) == "string" then return self:GetColor(val) end
	elseif key == "ChildGap" then
		if type(val) == "string" then return self:GetSize(val) end
	elseif key == "Size" or key == "IconSize" or key == "MinSize" or key == "MaxSize" then
		if type(val) == "string" then
			return Vec2() + self:GetSize(val)
		elseif type(val) == "number" then
			return Vec2() + val
		end
	elseif key == "Font" then
		if type(val) == "string" then
			local style, size = val:match("([^%s]+)%s*(.*)")

			if size == "" then size = nil end

			if not style or style == "" then style = "body" end

			if self:GetFontSizes()[style] and not self:GetFontStyles()[style] then
				size = style
				style = "body"
			end

			obj.theme_font_style = style

			if size then obj.theme_font_size = size end

			local font, size_val = self:GetFont(obj.theme_font_style, obj.theme_font_size)

			if font and obj.SetFontSize then obj:SetFontSize(size_val) end

			return font
		elseif type(val) == "table" and val.IsFont then
			obj.theme_font_style = nil

			if obj.SetFontSize then obj:SetFontSize(val:GetSize()) end

			return val
		end
	elseif key == "FontSize" then
		local size_val

		if type(val) == "string" then
			obj.theme_font_size = val
			size_val = self:ResolveFontSize(val)
		else
			obj.theme_font_size = nil
			size_val = val
		end

		if obj.SetFont then
			local font = self:GetFont(obj.theme_font_style or "body", obj.theme_font_size or size_val)

			if font then obj:SetFont(font) end
		end

		return size_val
	end

	return val
end

return BaseTheme:Register()
