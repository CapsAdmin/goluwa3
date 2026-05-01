local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local prototype = import("goluwa/prototype.lua")
local event = import("goluwa/event.lua")
local base = import("game/addons/gui/lua/ui/themes/base.lua")
local jrpg = import("game/addons/gui/lua/ui/themes/jrpg.lua")
local theme = library()
local DEFAULT_PRESET_NAME = base.Name
local FONT_SIZE_ORDER = {"XS", "S", "M", "L", "XL", "XXL", "XXXL"}
local FONT_NAME_ORDER = {"heading", "body_weak", "body", "body_strong"}
local ICON_METHODS = {
	disclosure = "DrawDisclosureIcon",
	dropdown_indicator = "DrawDropdownIndicatorIcon",
	close = "DrawCloseIcon",
}
theme.themes = {base, jrpg}
theme.implementations = {}
theme.active = nil

local function find_theme_class(name)
	if name == nil or name == DEFAULT_PRESET_NAME then return base end

	for _, theme_class in ipairs(theme.themes) do
		if theme_class.Name == name then return theme_class end
	end

	return base
end

function theme.LoadTheme(name)
	local theme_class = find_theme_class(name)
	local object = theme.implementations[theme_class.Name]

	if not object then
		object = theme_class:CreateObject()
		object:SetThemeContext(theme)
		object:Initialize()
		theme.implementations[theme_class.Name] = object
	end

	theme.active = object
	theme.font_sizes = object:GetFontSizes()
	theme.font_styles = object:GetFontStyles()
	return object
end

function theme.GetTheme()
	return theme.active
end

function theme.OnSetProperty(obj, key, val)
	if key == "Padding" then
		if type(val) == "string" then return Rect() + theme.GetPadding(val) end
	elseif key == "Color" then
		if type(val) == "string" then return theme.GetColor(val) end
	elseif key == "ChildGap" then
		if type(val) == "string" then return theme.GetSize(val) end
	elseif key == "Size" then
		if type(val) == "string" then return Vec2() + theme.GetSize(val) end
	elseif key == "Font" then
		if type(val) == "string" then
			local style, size = val:match("([^%s]+)%s*(.*)")

			if size == "" then size = nil end

			if not style or style == "" then style = "body" end

			if theme.font_sizes[style] and not theme.font_styles[style] then
				size = style
				style = "body"
			end

			obj.theme_font_style = style

			if size then obj.theme_font_size = size end

			local font, size_val = theme.GetFont(obj.theme_font_style, obj.theme_font_size)

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
			size_val = theme.GetFontSize(val)
		else
			obj.theme_font_size = nil
			size_val = val
		end

		if obj.SetFont then
			local font = theme.GetFont(obj.theme_font_style or "body", obj.theme_font_size or size_val)

			if font then obj:SetFont(font) end
		end

		return size_val
	end

	return val
end

event.AddListener("OnEntitySetProperty", "theme.OnSetProperty", theme.OnSetProperty)

do
	local function resolve_draw_target(target)
		if not target then error("draw target is required", 2) end

		if target.Owner then return target.Owner, target end

		if target.gui_element then return target, target.gui_element end

		error("invalid draw target", 2)
	end

	function theme.GetDrawContext(target, include_draw_size_offset)
		local panel, gui = resolve_draw_target(target)
		local size = include_draw_size_offset and
			panel.transform:GetTotalSize() or
			panel.transform:GetSize()
		return {
			size = size,
			alpha = gui.DrawAlpha,
			radius = gui.GetBorderRadius and gui:GetBorderRadius() or 0,
		}
	end

	local function bind_panel_state(pnl, state)
		if state then state.pnl = pnl end

		return state
	end

	function theme.UpdateButtonAnimations(pnl, state)
		return theme.active:UpdateButtonAnimations(bind_panel_state(pnl, state))
	end

	function theme.UpdateSliderAnimations(pnl, state)
		return theme.active:UpdateSliderAnimations(bind_panel_state(pnl, state))
	end

	function theme.UpdateCheckboxAnimations(pnl, state)
		return theme.active:UpdateCheckboxAnimations(bind_panel_state(pnl, state))
	end
end

do
	function theme.GetName()
		return theme.active:GetName()
	end

	function theme.GetAvailable()
		local out = {}

		for i, theme_class in ipairs(theme.themes) do
			out[i] = theme_class.Name
		end

		return out
	end

	function theme.GetSurfaceColor(name)
		return theme.active:GetSurfaceColor(name)
	end

	function theme.GetColor(name, opts)
		return theme.active:GetColor(name, opts)
	end

	function theme.GetColorOn(name, surface)
		return theme.active:GetColorOn(name, surface)
	end

	function theme.WithSurface(surface, callback, ...)
		return theme.active:WithSurface(surface, callback, ...)
	end

	function theme.GetCurrentSurface()
		return theme.active:GetCurrentSurface()
	end

	function theme.ResolveColor(value, fallback)
		return theme.active:ResolveColor(value, fallback)
	end

	function theme.ResolveSurfaceColor(value, fallback)
		return theme.active:ResolveSurfaceColor(value, fallback)
	end

	function theme.GetSize(size_name)
		return theme.active:GetSize(size_name)
	end

	function theme.GetPadding(size_name)
		return theme.active:GetPadding(size_name)
	end

	function theme.GetRadius(radius_name)
		return theme.active:GetRadius(radius_name)
	end

	function theme.GetFontSizes()
		local list = {}
		local font_sizes = theme.active:GetFontSizes()

		for _, name in ipairs(FONT_SIZE_ORDER) do
			if font_sizes[name] then table.insert(list, name) end
		end

		return list
	end

	function theme.GetFontNames()
		local list = {}
		local font_styles = theme.active:GetFontStyles()

		for _, name in ipairs(FONT_NAME_ORDER) do
			if font_styles[name] then table.insert(list, name) end
		end

		return list
	end

	function theme.GetFontSize(size_name)
		return theme.active:ResolveFontSize(size_name)
	end

	function theme.GetFont(name, size_name)
		return theme.active:GetFont(name, size_name)
	end

	theme.LoadTheme(DEFAULT_PRESET_NAME)
end

return theme
