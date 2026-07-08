local T = import("test/environment.lua")
local test_render = import("test/test_render.lua")
test_render.Init2D()
local theme = import("goluwa/render2d/ui/theme.lua")

T.Pending("theme color surface scope resolves semantic colors against the current background", function()
	local previous_preset = theme.active:GetName()
	theme.LoadTheme("minimal")
	local surface = theme.active:GetColor("surface")
	local raw_surface = theme.GetSurfaceColor("surface")
	local surface_on_surface = theme.active:ResolveColor("surface", "surface")
	local surface_alt = theme.active:GetColor("surface_alt")
	local text_on_surface = theme.active:ResolveColor("text", "surface")
	local unscoped = theme.active:GetColor("text_on_accent")
	local explicit = theme.active:ResolveColor("text_on_accent", "negative")
	local underline = theme.active:GetColor("underline")
	local fallback = theme.active:GetColor("property_selection")
	local explicit_fallback = theme.active:ResolveColor("property_selection", "negative")
	local stacked_surface = theme.WithSurface("surface", function()
		return theme.active:GetColor("surface")
	end)
	local raw_surface_on_negative = theme.WithSurface("negative", function()
		return theme.GetSurfaceColor("surface")
	end)
	local stacked, stacked_fallback, current_surface = theme.WithSurface("negative", function()
		return theme.active:GetColor("text_on_accent"),
		theme.active:GetColor("property_selection"),
		theme.GetCurrentSurface()
	end)
	T(raw_surface:ToHex())["=="](surface:ToHex())
	T(surface_on_surface:ToHex())["=="](surface:ToHex())
	T(stacked_surface:ToHex())["=="](surface:ToHex())
	T(raw_surface_on_negative:ToHex())["=="](raw_surface:ToHex())
	T(underline:ToHex())["=="](theme.active:GetPalette():Get("underline"):ToHex())
	assert(surface_alt:ToHex() ~= surface:ToHex())
	assert(text_on_surface:GetContrastRatio(surface) >= 4.5)
	T(stacked:ToHex())["=="](explicit:ToHex())
	assert(stacked:ToHex() ~= unscoped:ToHex())
	T(stacked_fallback:ToHex())["=="](explicit_fallback:ToHex())
	assert(stacked_fallback:ToHex() ~= fallback:ToHex())
	T(current_surface)["=="]("negative")
	T(theme.GetCurrentSurface())["=="](nil)
	theme.LoadTheme(previous_preset)
	theme.active:ClearSurfaceStack()
end)

T.Pending("extended presets can override semantic theme tokens explicitly", function()
	local previous_preset = theme.active:GetName()
	theme.LoadTheme("minimal")
	theme.active:ClearSurfaceStack()
	local preset = theme.active:GetPalette()
	T(theme.GetSurfaceColor("surface_alt"):ToHex())["=="](preset:Get("surface_alt"):ToHex())
	T(theme.active:GetColor("surface_alt"):ToHex())["=="](preset:Get("surface_alt"):ToHex())
	T(theme.active:GetColor("primary"):ToHex())["=="](preset:Get("primary"):ToHex())
	theme.LoadTheme(previous_preset)
	theme.active:ClearSurfaceStack()
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
