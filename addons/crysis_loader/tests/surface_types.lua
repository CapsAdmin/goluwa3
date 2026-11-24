local T = import("test/environment.lua")
local surface_types = import("goluwa/surface_types.lua")
local cry_surfaces = import("lua/crysis_loader/surface_types.lua")

T.Test("crysis translator only produces engine surface types", function()
	for _, name in ipairs{
		"mat_metal_sheet",
		"mat_wood_breakable_medium",
		"mat_pebble",
		"mat_alien_flesh",
		"mat_nothing",
	} do
		T(surface_types.Set[cry_surfaces.Translate(name)])["=="](true)
	end

	T(cry_surfaces.Translate("mat_metal_sheet"))["=="]("metal_vent")
	T(cry_surfaces.Translate("mat_wood_breakable_medium"))["=="]("wood")
	T(cry_surfaces.Translate("mat_nothing"))["=="]("default")
end)
