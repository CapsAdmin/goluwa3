local T = import("test/environment.lua")
local keyframes = import("lua/keyframes.lua")
local movesets = import("lua/movesets.lua")
local move_edit = import("lua/jrpg/move_edit.lua")
import("addons/jrpg/lua/autorun/weapons.lua")

local function find_row(rows, name)
	for _, row in ipairs(rows) do
		if row.Name == name then return row end
	end
end

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

T.Test("move rows list a key per frame that sets a track and the events", function()
	local move = table.copy(movesets.Source.sword.Moves.dive_throw)
	local rows = move_edit.Rows(move)
	T(#find_row(rows, "carry").Keys)["=="](3)
	T(#find_row(rows, "grip").Keys)["=="](4)
	T(#find_row(rows, "latch").Keys)["=="](1)
	T(#find_row(rows, "release").Keys)["=="](1)
	T(#find_row(rows, "hit").Keys)["=="](0)
	T(find_row(rows, "pose").Keys[1].Label)["=="]("thrust_windup")
	T(find_row(rows, "carry").Keys[1].Frame[1])["=="](0.4)
end)

T.Test("moving, splitting and removing keys keeps the frames ordered and valid", function()
	local data = table.copy(movesets.Source.sword)
	local move = data.Moves.dive_throw
	local frame = move.Keys[1]
	local count = #move.Keys
	local index = move_edit.MoveFrame(move, frame, 0.5)
	T(move.Keys[index])["=="](frame)

	for i = 2, #move.Keys do
		T(move.Keys[i][1] >= move.Keys[i - 1][1])["=="](true)
	end

	local split = move_edit.Split(move, frame, "body")
	T(split.body)["~="](nil)
	T(frame.body)["=="](nil)
	T(frame[2])["=="]("thrust_windup")
	move_edit.RemoveTrack(move, split, "body")
	T(#move.Keys)["=="](count)
	move_edit.RemovePose(move, frame)
	T(#move.Keys)["=="](count - 1)
	local added = move_edit.AddTrackKey(move, "torso", 0.3, {0.2})
	T(move.Keys[move_edit.Find(move.Keys, added)])["=="](added)
	movesets.Update("sword", data)
	T(movesets.Get("sword").Moves.dive_throw.TorsoKeys ~= nil)["=="](true)
	movesets.Update("sword", table.copy(movesets.Source.sword))
end)

T.Test("sampling a track returns the values in the units the file uses", function()
	local move = movesets.Get("sword").Moves.dash
	local values = move_edit.Sample(move, "motion", 0.32)
	T(values[1])["=="](40)
	T(values[2])["=="](1.3)
	T(#move_edit.Sample(move, "carry", 0.3))["=="](9)
end)

T.Test("events can be added, moved in order and given their fields", function()
	local move = table.copy(movesets.Source.sword.Moves.light_1)
	local event = move_edit.AddEvent(move, "release", 0.1)
	T(move.Events[1])["=="](event)
	T(event.Throw[3])["=="](2)
	move_edit.RemoveEvent(move, event)
	T(#move.Events)["=="](1)
	local fields = move_edit.GetEventFields("hit")
	T(fields[1].Name)["=="]("Cut")
	T(fields[1].Count)["=="](3)
end)
