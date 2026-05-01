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

T.Test("text element resolves explicit color tokens against surface color", function()
	local previous_preset = theme.GetName()
	theme.LoadTheme("minimal")
	local Text = import("game/addons/gui/lua/ui/elements/text.lua")
	local label = Text{
		Color = "text_on_accent",
		SurfaceColor = "primary",
	}
	local resolved = label:CallLocalEvent("OnGetTextColor")
	local expected = theme.GetColorOn("text_on_accent", "primary")
	T(resolved:ToHex())["=="](expected:ToHex())
	assert(resolved:GetContrastRatio(theme.GetColor("primary")) >= 4.5)
	label:Remove()
	theme.LoadTheme(previous_preset)
	theme.GetTheme():ClearSurfaceStack()
end)

T.Test("text element can resolve color from current theme surface context", function()
	local previous_preset = theme.GetName()
	theme.LoadTheme("minimal")
	local Text = import("game/addons/gui/lua/ui/elements/text.lua")
	local label = Text{
		Color = "text_on_accent",
	}
	local resolved = theme.WithSurface("primary", function()
		return label:CallLocalEvent("OnGetTextColor")
	end)
	local expected = theme.GetColorOn("text_on_accent", "primary")
	T(resolved:ToHex())["=="](expected:ToHex())
	label:Remove()
	theme.LoadTheme(previous_preset)
	theme.GetTheme():ClearSurfaceStack()
end)

T.Test("button text color follows hovered surface context", function()
	local previous_preset = theme.GetName()
	theme.LoadTheme("minimal")
	local Button = import("game/addons/gui/lua/ui/widgets/button.lua")
	local button = Button{Text = "Button"}
	local label = button:GetChildren()[1]
	button.mouse_input:OnHover(true)
	local resolved = label:CallLocalEvent("OnGetTextColor")
	local hover_surface = button:CallLocalEvent("OnGetSurfaceColor")
	local expected = theme.GetColorOn("text", hover_surface)
	T(resolved:ToHex())["=="](expected:ToHex())
	button:Remove()
	theme.LoadTheme(previous_preset)
	theme.GetTheme():ClearSurfaceStack()
end)

T.Test("dropdown text color follows hovered surface context", function()
	local previous_preset = theme.GetName()
	theme.LoadTheme("minimal")
	local Dropdown = import("game/addons/gui/lua/ui/widgets/dropdown.lua")
	local dropdown = Dropdown{
		Options = {{Text = "A", Value = 1}},
		Value = 1,
	}
	local label = dropdown:GetChildren()[1]
	dropdown.mouse_input:OnHover(true)
	local resolved = label:CallLocalEvent("OnGetTextColor")
	local hover_surface = dropdown:CallLocalEvent("OnGetSurfaceColor")
	local expected = theme.GetColorOn("text", hover_surface)
	T(resolved:ToHex())["=="](expected:ToHex())
	dropdown:Remove()
	theme.LoadTheme(previous_preset)
	theme.GetTheme():ClearSurfaceStack()
end)

T.Test("collapsible header text color follows hovered surface context", function()
	local previous_preset = theme.GetName()
	theme.LoadTheme("minimal")
	local Collapsible = import("game/addons/gui/lua/ui/widgets/collapsible.lua")
	local collapsible = Collapsible{
		HeaderMode = "filled",
		Title = "Category",
	}
	local header = collapsible:GetChildren()[1]
	local label = header:GetChildren()[2]
	header.mouse_input:OnHover(true)
	local resolved = label:CallLocalEvent("OnGetTextColor")
	local hover_surface = header:CallLocalEvent("OnGetSurfaceColor")
	local expected = theme.GetColorOn("text", hover_surface)
	T(resolved:ToHex())["=="](expected:ToHex())
	collapsible:Remove()
	theme.LoadTheme(previous_preset)
	theme.GetTheme():ClearSurfaceStack()
end)
