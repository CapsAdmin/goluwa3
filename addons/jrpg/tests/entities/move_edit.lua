local T = import("test/environment.lua")
local movesets = import("lua/jrpg/movesets.lua")
import("addons/jrpg/lua/autorun/weapons.lua")

T.Test("moveset source round trips through the text a save writes", function()
	for _, name in ipairs{"sword", "greatsword", "rapier", "reaper"} do
		local back = assert(loadstring(table.to_source(movesets.Source[name], {"Moves", "Keys"})))()
		T(table.equal(back, movesets.Source[name]))["=="](true)
	end
end)

T.Test("editing a moveset copy and updating it changes the registered move", function()
	local data = table.copy(movesets.Source.sword)
	local move = data.Moves.light_1
	local before = movesets.Get("sword").Moves.light_1.Duration
	move.Duration = before + 0.25
	movesets.Update("sword", data)
	T(movesets.Get("sword").Moves.light_1.Duration)["=="](before + 0.25)
	T(movesets.Get("sword").Combo[1])["=="](movesets.Get("sword").Moves.light_1)
	move.Duration = before
	movesets.Update("sword", data)
	T(movesets.Get("sword").Moves.light_1.Duration)["=="](before)
end)

T.Test("an update that does not validate leaves the registered moveset alone", function()
	local data = table.copy(movesets.Source.sword)
	data.Moves.light_1.Keys[1][1] = 2
	local ok = pcall(movesets.Update, "sword", data)
	T(ok)["=="](false)
	T(movesets.Get("sword").Moves.light_1.Keys[1][1])["<="](1)
end)
