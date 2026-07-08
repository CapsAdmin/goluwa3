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
		object:Initialize(theme)
		theme.implementations[theme_class.Name] = object
	end

	theme.active = object
	theme.font_sizes = object:GetFontSizes()
	theme.font_styles = object:GetFontStyles()
	return object
end

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
