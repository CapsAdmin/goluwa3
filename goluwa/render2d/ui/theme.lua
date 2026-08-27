local base = import("goluwa/render2d/ui/themes/base.lua")
local jrpg = import("goluwa/render2d/ui/themes/jrpg.lua")
local playful = import("goluwa/render2d/ui/themes/playful.lua")
local theme = library()
local DEFAULT_PRESET_NAME = base.Name
theme.themes = {base, jrpg, playful}
theme.active = nil

local function find_theme_class(name)
	if name == nil or name == DEFAULT_PRESET_NAME then return base end

	for _, theme_class in ipairs(theme.themes) do
		if theme_class.Name == name then return theme_class end
	end

	return base
end

function theme.LoadTheme(name)
	if theme.active and theme.active.Name == name then return end

	local theme_class = find_theme_class(name)
	local object = theme_class:CreateObject()
	object:Initialize()
	theme.active = object
	return object
end

function theme.GetAvailable()
	local out = {}

	for i, theme_class in ipairs(theme.themes) do
		out[i] = theme_class.Name
	end

	return out
end

theme.LoadTheme(DEFAULT_PRESET_NAME)
return theme
