local T = import("test/environment.lua")
local list = import("goluwa/list.lua")
local emitters = import("lua/emitters.lua")

T.Test("emitters load the shipped files, hand out realized copies and name duplicates", function()
	for _, name in ipairs{"hit_position", "hit_normal", "hit_force", "muzzle_flash", "tool_hit", "melee_sparks"} do
		T(not not table.has_value(emitters.Names, name))["=="](true)
	end

	local properties = emitters.Get("melee_sparks")
	T(properties.RatePerMeter)["=="](20)
	T(properties.ColorStart.r)["=="](1)
	T(properties.ColorEnd.a)["=="](0)
	properties.RatePerMeter = 5
	properties.ColorStart.r = 0.5
	T(emitters.Files.Source.melee_sparks.RatePerMeter)["=="](20)
	T(emitters.Files.Source.melee_sparks.ColorStart[1])["=="](1)
	T(emitters.GetNewName("tool_hit"))["=="]("tool_hit_2")
	emitters.Create("tool_hit_2", "tool_hit")
	T(not not table.has_value(emitters.Names, "tool_hit_2"))["=="](true)
	T(emitters.GetNewName("tool_hit"))["=="]("tool_hit_3")
	T(emitters.Get("tool_hit_2").SpeedMax)["=="](emitters.Get("tool_hit").SpeedMax)
	list.remove_value(emitters.Names, "tool_hit_2")
	emitters.Files.Source.tool_hit_2 = nil
end)
