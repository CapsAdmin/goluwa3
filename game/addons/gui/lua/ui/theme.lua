local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local minimal = import("game/addons/gui/lua/ui/themes/minimal.lua")
local jrpg = import("game/addons/gui/lua/ui/themes/jrpg.lua")

local theme = library()
local DEFAULT_PRESET_NAME = "jrpg"
local FONT_SIZE_ORDER = {"XS", "S", "M", "L", "XL", "XXL", "XXXL"}
local FONT_NAME_ORDER = {"heading", "body_weak", "body", "body_strong"}
local ICON_NAMES = {
	"disclosure",
	"dropdown_indicator",
	"close",
}
local PANEL_NAMES = {
	"button",
	"surface",
	"button_post",
	"slider",
	"checkbox",
	"button_radio",
	"frame",
	"frame_post",
	"menu_spacer",
	"header",
	"progress_bar",
	"divider",
}
local theme_modules = {
	jrpg = jrpg,
	minimal = minimal,
}

theme.preset_order = {"jrpg", "minimal"}
theme.presets = {}
theme.implementations = {}

for _, name in ipairs(theme.preset_order) do
	local module = theme_modules[name]
	theme.presets[name] = module.preset
	theme.implementations[name] = module.create_runtime(theme)
end

local function get_active_preset()
	return theme.presets[theme.current_preset_name] or theme.presets[DEFAULT_PRESET_NAME]
end

local function get_default_runtime()
	return theme.implementations[DEFAULT_PRESET_NAME]
end

local function get_active_runtime()
	return theme.implementations[theme.GetPresetName()] or get_default_runtime()
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

do
	local function sync_preset_fields()
		local preset = get_active_preset()
		theme.font_sizes = preset.font_sizes
		theme.font_styles = preset.font_styles
	end

	function theme.SetPreset(name)
		if not theme.presets[name] then name = DEFAULT_PRESET_NAME end

		theme.current_preset_name = name
		sync_preset_fields()
		return name
	end

	function theme.GetPresetName()
		return theme.current_preset_name or DEFAULT_PRESET_NAME
	end

	function theme.GetPresetLabel(name)
		local preset = theme.presets[name or theme.GetPresetName()] or theme.presets[DEFAULT_PRESET_NAME]
		return preset.label
	end

	function theme.GetPresetNames()
		return theme.preset_order
	end

	function theme.GetColor(name)
		local colors = get_active_preset().colors
		return colors[name or "primary"] or colors.primary
	end

	function theme.GetSize(size_name)
		local sizes = get_active_preset().sizes
		size_name = size_name or "default"
		return sizes[size_name] or sizes.default
	end

	function theme.GetPadding(size_name)
		return theme.GetSize(size_name)
	end

	function theme.GetFontSizes()
		local list = {}

		for _, name in ipairs(FONT_SIZE_ORDER) do
			if theme.font_sizes[name] then table.insert(list, name) end
		end

		return list
	end

	function theme.GetFontNames()
		local list = {}

		for _, name in ipairs(FONT_NAME_ORDER) do
			if theme.font_styles[name] then table.insert(list, name) end
		end

		return list
	end

	function theme.GetFontSize(size_name)
		if type(size_name) == "number" then return size_name end

		return theme.font_sizes[size_name or "M"] or theme.font_sizes.M
	end

	function theme.GetFont(name, size_name)
		if name and not size_name then
			local parsed_name, parsed_size = name:match("([^%s]+)%s*(.*)")

			if parsed_size and parsed_size ~= "" then name, size_name = parsed_name, parsed_size end
		end

		if theme.font_sizes[name] and not theme.font_styles[name] then
			size_name = name
			name = "body"
		end

		local preset = get_active_preset()
		local style = theme.font_styles[name or "body"] or theme.font_styles.body
		local size_val = theme.GetFontSize(size_name)
		local font_props = {Size = size_val}
		local cache_key

		if style.Path then
			font_props.Path = style.Path
			cache_key = "path_" .. style.Path .. "_" .. size_val
		else
			font_props.Name = style.Name or style[1]
			font_props.Weight = style.Weight or style[2]
			cache_key = font_props.Name .. "_" .. (font_props.Weight or "Regular") .. "_" .. size_val
		end

		if not preset.font_cache[cache_key] then
			preset.font_cache[cache_key] = fonts.New(font_props)
		end

		return preset.font_cache[cache_key], size_val
	end

	theme.current_preset_name = theme.current_preset_name or DEFAULT_PRESET_NAME
	theme.SetPreset(theme.current_preset_name)
end

do
	theme.icons = {}
	theme.panels = {}

	function theme.UpdateButtonAnimations(pnl, state)
		return get_active_runtime().UpdateButtonAnimations(pnl, state)
	end

	function theme.UpdateSliderAnimations(pnl, state)
		return get_active_runtime().UpdateSliderAnimations(pnl, state)
	end

	function theme.UpdateCheckboxAnimations(pnl, state)
		return get_active_runtime().UpdateCheckboxAnimations(pnl, state)
	end

	for _, name in ipairs(ICON_NAMES) do
		theme.icons[name] = function(...)
			return get_active_runtime().icons[name](...)
		end
	end

	for _, name in ipairs(PANEL_NAMES) do
		theme.panels[name] = function(...)
			return get_active_runtime().panels[name](...)
		end
	end
end

return theme
