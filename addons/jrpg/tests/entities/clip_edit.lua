local T = import("test/environment.lua")
local clip_edit = import("lua/jrpg/clip_edit.lua")

T.Test("clip edit moves, adds and removes keys of tracks and events", function()
	local data = {
		Tracks = {ring = {{0, 0}, {1, 2}}, expr = "sin(f)"},
		Events = {{0.5, Call = "x"}},
	}
	local rows = clip_edit.Rows(data)
	T(#rows)["=="](3)
	T(rows[1].Name)["=="]("expr (expr)")
	T(#rows[1].Keys)["=="](0)
	T(#rows[2].Keys)["=="](2)
	T(rows[3].Keys[1].Label)["=="]("x")
	local selection = clip_edit.AddKey(data, rows[2], 0.5)
	T(selection.Index)["=="](2)
	T(data.Tracks.ring[2][2])["=="](1)
	clip_edit.MoveKey(data, rows[2], 2, 5)
	T(data.Tracks.ring[2][1] < 1)["=="](true)
	clip_edit.RemoveKey(data, selection)
	T(#data.Tracks.ring)["=="](2)
	clip_edit.RemoveKey(data, {Track = "ring", Index = 1})
	T(#data.Tracks.ring)["=="](2)
	local event = clip_edit.AddKey(data, rows[3], 0.2)
	T(event.Index)["=="](1)
	T(data.Events[1][1])["=="](0.2)
	clip_edit.RemoveKey(data, event)
	T(#data.Events)["=="](1)
end)
