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
	for _, name in ipairs{"sword", "greatsword", "rapier", "reaper", "shovel"} do
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

T.Test("removing and transforming selected keys keeps frames and events ordered", function()
	local move = table.copy(movesets.Source.sword.Moves.dive_throw)
	local rows = move_edit.Rows(move)
	local carry = find_row(rows, "carry")
	local count = #move.Keys
	local keys = {
		{Frame = carry.Keys[1].Frame, Track = "carry"},
		{Frame = carry.Keys[2].Frame, Track = "carry"},
		{Event = find_row(rows, "latch").Keys[1].Event},
	}
	local grabbed = move_edit.Grab(keys)
	local first_time = carry.Keys[1].Time
	local latch_time = keys[3].Event.At
	move_edit.Transform(move, grabbed, first_time, 2, 0, 0.005)
	T(carry.Keys[1].Frame[1])["=="](first_time)
	T(
		math.abs(carry.Keys[2].Frame[1] - (first_time + (carry.Keys[2].Time - first_time) * 2))
	)["<"](0.006)
	T(math.abs(keys[3].Event.At - (first_time + (latch_time - first_time) * 2)))["<"](0.006)

	for i = 2, #move.Keys do
		T(move.Keys[i][1] >= move.Keys[i - 1][1])["=="](true)
	end

	move_edit.Transform(move, grabbed, 0, 1, 0.1, 0.005)
	T(math.abs(keys[1].Frame[1] - (first_time + 0.1)))["<"](0.006)
	move_edit.RemoveKeys(move, keys)
	T(find_row(move_edit.Rows(move), "latch").Keys[1])["=="](nil)
	T(#find_row(move_edit.Rows(move), "carry").Keys)["=="](1)
	T(#move.Keys <= count)["=="](true)
end)

T.Test("unlinking a key moves its track or pose into a frame of its own", function()
	local move = table.copy(movesets.Source.sword.Moves.dive_throw)
	local frame = move.Keys[3]
	local pose_name = frame[2]
	T(type(pose_name))["=="]("string")
	T(move_edit.IsLinked{Frame = frame, Track = "body"})["=="](true)
	local count = #move.Keys
	local body = move_edit.Unlink(move, {Frame = frame, Track = "body"})
	T(body.Frame ~= frame)["=="](true)
	T(body.Frame.body ~= nil)["=="](true)
	T(frame.body)["=="](nil)
	T(#move.Keys)["=="](count + 1)
	T(move_edit.IsLinked(body))["=="](false)
	local pose = move_edit.Unlink(move, {Frame = frame})
	T(pose.Frame[2])["=="](pose_name)
	T(frame[2])["=="](nil)
end)

T.Test("linking selected keys merges them into the earliest frame unless a track would repeat", function()
	local move = table.copy(movesets.Source.sword.Moves.dive_throw)
	local frame = move.Keys[3]
	local pose_name = frame[2]
	local body = move_edit.Unlink(move, {Frame = frame, Track = "body"})
	local pose = {Frame = frame}
	T(move_edit.CanLink({body, pose}))["=="](true)
	T(move_edit.CanLink({body}))["=="](false)
	local count = #move.Keys
	local linked = move_edit.Link(move, {body, pose})
	T(linked[1].Frame)["=="](linked[2].Frame)
	T(linked[1].Frame[2])["=="](pose_name)
	T(linked[1].Frame.body ~= nil)["=="](true)
	T(#move.Keys)["=="](count - 1)
	T(move_edit.IsLinked(linked[1]))["=="](true)
	local other

	for _, candidate in ipairs(move.Keys) do
		if candidate ~= linked[1].Frame and candidate.body ~= nil then
			other = candidate
		end
	end

	T(other ~= nil)["=="](true)
	T(move_edit.CanLink{{Frame = other, Track = "body"}, linked[1]})["=="](false)
end)
