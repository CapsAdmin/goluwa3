local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local base = import("goluwa/render2d/ui/themes/base.lua")
local jrpg = import("goluwa/render2d/ui/themes/jrpg.lua")
local theme = library()
local DEFAULT_PRESET_NAME = base.Name
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

function theme.OnSetProperty(obj, key, val)
	if key == "Padding" then
		if type(val) == "string" then return Rect() + theme.active:GetPadding(val) end
	elseif key == "Color" then
		if type(val) == "string" then return theme.active:GetColor(val) end
	elseif key == "ChildGap" then
		if type(val) == "string" then return theme.active:GetSize(val) end
	elseif key == "Size" then
		if type(val) == "string" then return Vec2() + theme.active:GetSize(val) end
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

			local font, size_val = theme.active:GetFont(obj.theme_font_style, obj.theme_font_size)

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
			size_val = theme.active:ResolveFontSize(val)
		else
			obj.theme_font_size = nil
			size_val = val
		end

		if obj.SetFont then
			local font = theme.active:GetFont(obj.theme_font_style or "body", obj.theme_font_size or size_val)

			if font then obj:SetFont(font) end
		end

		return size_val
	end

	return val
end

event.AddListener("OnEntitySetProperty", "theme", theme.OnSetProperty)

event.AddListener("OnEntityStateChanged", "theme", function(pnl, key, val)
	theme.active:UpdateAnimations(pnl)
end)

do
	function theme.GetAvailable()
		local out = {}

		for i, theme_class in ipairs(theme.themes) do
			out[i] = theme_class.Name
		end

		return out
	end

	theme.LoadTheme(DEFAULT_PRESET_NAME)
end

return theme
