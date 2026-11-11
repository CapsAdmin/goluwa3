local T = import("test/environment.lua")
local surface_types = import("goluwa/surface_types.lua")
local source_surfaces = import("goluwa/source_engine/surface_types.lua")
local cry_surfaces = import("goluwa/cry_engine/surface_types.lua")
local source1 = import("lua/sound_profiles/source1.lua")

T.Test("source1 profile has impact and footstep sounds for every engine surface type", function()
	for _, name in ipairs(surface_types.List) do
		local impact = source1.GetImpact(name)
		T(#impact.soft > 0 and #impact.hard > 0)["=="](true)
		T(#source1.GetFootstep(name, 1) > 0)["=="](true)
	end
end)

T.Test("engine translators only produce engine surface types", function()
	for _, name in ipairs{
		"Metal_Box",
		"world.metal_grate",
		"prop.wood_gib_small",
		"stairs.metal",
		"npc_zombie_flesh",
		"unheard_of",
	} do
		T(surface_types.Set[source_surfaces.Translate(name)])["=="](true)
	end

	for _, name in ipairs{
		"mat_metal_sheet",
		"mat_wood_breakable_medium",
		"mat_pebble",
		"mat_alien_flesh",
		"mat_nothing",
	} do
		T(surface_types.Set[cry_surfaces.Translate(name)])["=="](true)
	end

	T(source_surfaces.Translate("Metal_Box"))["=="]("metal_box")
	T(source_surfaces.Translate("world.metal_grate"))["=="]("metal_grate")
	T(cry_surfaces.Translate("mat_metal_sheet"))["=="]("metal_vent")
	T(cry_surfaces.Translate("mat_wood_breakable_medium"))["=="]("wood")
	T(cry_surfaces.Translate("mat_nothing"))["=="]("default")
end)
