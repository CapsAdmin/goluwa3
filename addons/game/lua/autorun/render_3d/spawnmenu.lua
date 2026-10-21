local input = import("goluwa/input.lua")
local spawnmenu = import("lua/spawnmenu.lua")
input.Bind("q", "+spawnmenu", spawnmenu.Hold)
input.Bind("q", "-spawnmenu", spawnmenu.Release)

local game_history = import("lua/game_history.lua")
local event = import("goluwa/event.lua")
local history = game_history.history
event.AddListener("KeyInput", "game_history", function(key, press)
	if not press or key ~= "z" or spawnmenu.IsEditing() then return end

	if input.IsControlDown() and input.IsShiftDown() then
		history:Redo()
		return true
	end

	if not input.IsControlDown() and not input.IsShiftDown() then
		history:Undo()
		return true
	end
end)
