local event = import("goluwa/event.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local base = import("goluwa/render2d/ui/themes/base.lua")
local jrpg = import("goluwa/render2d/ui/themes/jrpg.lua")
local playful = import("goluwa/render2d/ui/themes/playful.lua")
local retro = import("goluwa/render2d/ui/themes/retro.lua")
local derma = import("goluwa/render2d/ui/themes/derma.lua")
local derma_dark = import("goluwa/render2d/ui/themes/derma_dark.lua")
local zsnes = import("goluwa/render2d/ui/themes/zsnes.lua")
local theme = {}
local DEFAULT_PRESET_NAME = jrpg.Name
theme.themes = {base, jrpg, playful, retro, derma, derma_dark, zsnes}

local function find_theme_class(name)
	if name == nil then return jrpg end

	for _, theme_class in ipairs(theme.themes) do
		if theme_class.Name == name then return theme_class end
	end

	return base
end

function theme.LoadTheme(name)
	local active = rawget(theme, "active")

	if active and active.Name == name then return end

	local theme_class = find_theme_class(name)
	if active then active:Deactivate() end

	local object = theme_class:CreateObject()
	object:Initialize()
	object:Activate()
	theme.active = object
	event.Call("ThemeChanged")
	return object
end

function theme.Dynamic(fn, a, b, c)
	return setmetatable({fn, a, b, c}, base.DynamicMeta)
end

function theme.InputSize(active, width, font_size)
	return Vec2(width, active:GetInputHeight(font_size or "M"))
end

function theme.ItemPadding(active)
	local horizontal = active:GetPadding("M")
	local vertical = active:GetPadding("S")
	return Rect(horizontal, vertical, horizontal, vertical)
end

function theme.GetAvailable()
	local out = {}

	for i, theme_class in ipairs(theme.themes) do
		out[i] = theme_class.Name
	end

	return out
end

setmetatable(
	theme,
	{
		__index = function(self, key)
			if key == "active" then return self.LoadTheme(DEFAULT_PRESET_NAME) end
		end,
	}
)
return theme
