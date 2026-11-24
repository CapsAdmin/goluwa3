local T = import("test/environment.lua")
local vfs = import("goluwa/vfs.lua")
local steam = import("goluwa/steam/steam.lua")
local surface_types = import("goluwa/surface_types.lua")
local source_surfaces = import("lua/source_loader/surface_types.lua")
local source1 = import("lua/sound_profiles/source1.lua")

T.Test("source1 profile has impact and footstep sounds for every engine surface type", function()
	for _, name in ipairs(surface_types.List) do
		local impact = source1.GetImpact(name)
		T(#impact.soft > 0 and #impact.hard > 0)["=="](true)
		T(#source1.GetFootstep(name, 1) > 0)["=="](true)
	end
end)

T.Test("source translator only produces engine surface types", function()
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

	T(source_surfaces.Translate("Metal_Box"))["=="]("metal_box")
	T(source_surfaces.Translate("world.metal_grate"))["=="]("metal_grate")
end)

T.Test("source 2 sound profile", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local profile = import("lua/sound_profiles/source2.lua")
	local impact = profile.GetImpact("concrete")
	T(#impact.soft > 0 and #impact.hard > 0)["=="](true)
	T(vfs.IsFile(impact.soft[1]))["=="](true)
	local step = profile.GetFootstep("metal", 2)
	T(step[1]:find("metal_solid", 1, true) ~= nil)["=="](true)
	T(vfs.IsFile(step[1]))["=="](true)
	T(profile.GetFootstep("metal", 0.5)[1]:find("step_light", 1, true) ~= nil)["=="](true)
	T(profile.GetFootstep("metal", 5)[1]:find("step_run", 1, true) ~= nil)["=="](true)
	T(import("lua/sound_profiles.lua").Get())["=="](profile)
end)
