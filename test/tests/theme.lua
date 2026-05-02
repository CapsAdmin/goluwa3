local T = import("test/environment.lua")
local test_render = import("test/test_render.lua")
test_render.Init2D()
local theme = import("game/addons/gui/lua/ui/theme.lua")

T.Test("theme color surface scope resolves semantic colors against the current background", function()
	local previous_preset = theme.GetName()
	theme.LoadTheme("minimal")
	local surface = theme.GetColor("surface")
	local raw_surface = theme.GetSurfaceColor("surface")
	local surface_on_surface = theme.GetColorOn("surface", "surface")
	local surface_alt = theme.GetColor("surface_alt")
	local text_on_surface = theme.GetColorOn("text", "surface")
	local unscoped = theme.GetColor("text_on_accent")
	local explicit = theme.GetColorOn("text_on_accent", "negative")
	local underline = theme.GetColor("underline")
	local fallback = theme.GetColor("property_selection")
	local explicit_fallback = theme.GetColorOn("property_selection", "negative")
	local stacked_surface = theme.WithSurface("surface", function()
		return theme.GetColor("surface")
	end)
	local raw_surface_on_negative = theme.WithSurface("negative", function()
		return theme.GetSurfaceColor("surface")
	end)
	local stacked, stacked_fallback, current_surface = theme.WithSurface("negative", function()
		return theme.GetColor("text_on_accent"),
		theme.GetColor("property_selection"),
		theme.GetCurrentSurface()
	end)
	T(raw_surface:ToHex())["=="](surface:ToHex())
	T(surface_on_surface:ToHex())["=="](surface:ToHex())
	T(stacked_surface:ToHex())["=="](surface:ToHex())
	T(raw_surface_on_negative:ToHex())["=="](raw_surface:ToHex())
	T(underline:ToHex())["=="](theme.GetTheme():GetPalette():Get("underline"):ToHex())
	assert(surface_alt:ToHex() ~= surface:ToHex())
	assert(text_on_surface:GetContrastRatio(surface) >= 4.5)
	T(stacked:ToHex())["=="](explicit:ToHex())
	assert(stacked:ToHex() ~= unscoped:ToHex())
	T(stacked_fallback:ToHex())["=="](explicit_fallback:ToHex())
	assert(stacked_fallback:ToHex() ~= fallback:ToHex())
	T(current_surface)["=="]("negative")
	T(theme.GetCurrentSurface())["=="](nil)
	theme.LoadTheme(previous_preset)
	theme.GetTheme():ClearSurfaceStack()
end)

T.Test("extended presets can override semantic theme tokens explicitly", function()
	local previous_preset = theme.GetName()
	theme.LoadTheme("minimal")
	theme.GetTheme():ClearSurfaceStack()
	local preset = theme.GetTheme():GetPalette()
	T(theme.GetSurfaceColor("surface_alt"):ToHex())["=="](preset:Get("surface_alt"):ToHex())
	T(theme.GetColor("surface_alt"):ToHex())["=="](preset:Get("surface_alt"):ToHex())
	T(theme.GetColor("primary"):ToHex())["=="](preset:Get("primary"):ToHex())
	theme.LoadTheme(previous_preset)
	theme.GetTheme():ClearSurfaceStack()
end)

T.Test("theme preset list includes base theme", function()
	local names = theme.GetAvailable()
	local found = false

	for _, name in ipairs(names) do
		if name == "base" then
			found = true

			break
		end
	end

	assert(found)
end)
