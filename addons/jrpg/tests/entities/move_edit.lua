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
	local rows = move_edit.Rows(move, movesets.Source.sword)
	T(#find_row(rows, "carry").Keys)["=="](3)
	T(#find_row(rows, "grip").Keys)["=="](4)
	T(#find_row(rows, "latch").Keys)["=="](1)
	T(#find_row(rows, "release").Keys)["=="](1)
	T(#find_row(rows, "hit").Keys)["=="](0)
	T(find_row(rows, "poses").Keys[1].Label)["=="]("dive_throw")
	T(#find_row(rows, "poses").Keys[1].Marks > 2)["=="](true)
	T(find_row(rows, "poses").Keys[1].Entry)["=="](move.Overlays[1])
	T(find_row(rows, "poses").Keys[1].Link)["=="](move.Overlays[1])
	T(find_row(rows, "body").Keys[1].Link)["=="](move.Overlays[1])
	T(find_row(rows, "carry").Keys[1].Frame[1])["=="](0.4)
end)

T.Test("moving, splitting and removing keys keeps the frames ordered and valid", function()
	local pristine = table.copy(movesets.Source.sword)
	local data = table.copy(pristine)
	local move = data.Moves.dive_throw
	local frame = move.Keys[4]
	T(frame.carry ~= nil and frame.grip ~= nil)["=="](true)
	local count = #move.Keys
	local index = move_edit.MoveFrame(move, frame, 0.5)
	T(move.Keys[index])["=="](frame)

	for i = 2, #move.Keys do
		T(move.Keys[i][1] >= move.Keys[i - 1][1])["=="](true)
	end

	local split = move_edit.Split(move, frame, "grip")
	T(split.grip)["~="](nil)
	T(frame.grip)["=="](nil)
	T(frame.carry)["~="](nil)
	move_edit.RemoveTrack(move, split, "grip")
	T(#move.Keys)["=="](count)
	move_edit.RemoveTrack(move, frame, "carry")
	T(#move.Keys)["=="](count - 1)
	local added = move_edit.AddTrackKey(move, "attach", 0.3, {0.5})
	T(move.Keys[move_edit.Find(move.Keys, added)])["=="](added)
	movesets.Update("sword", data)
	T(movesets.Get("sword").Moves.dive_throw.AttachKeys ~= nil)["=="](true)
	movesets.Update("sword", pristine)
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
	local rows = move_edit.Rows(move, movesets.Source.sword)
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
	T(find_row(move_edit.Rows(move, movesets.Source.sword), "latch").Keys[1])["=="](nil)
	T(#find_row(move_edit.Rows(move, movesets.Source.sword), "carry").Keys)["=="](1)
	T(#move.Keys <= count)["=="](true)
end)

T.Test("unlinking a key moves its track into a frame of its own", function()
	local move = table.copy(movesets.Source.sword.Moves.dive_throw)
	local frame = move.Keys[4]
	T(move_edit.IsLinked{Frame = frame, Track = "carry"})["=="](true)
	local count = #move.Keys
	local carry = move_edit.Unlink(move, {Frame = frame, Track = "carry"})
	T(carry.Frame ~= frame)["=="](true)
	T(carry.Frame.carry ~= nil)["=="](true)
	T(frame.carry)["=="](nil)
	T(#move.Keys)["=="](count + 1)
	T(move_edit.IsLinked(carry))["=="](false)
end)

T.Test("linking selected keys merges them into the earliest frame unless a track would repeat", function()
	local move = table.copy(movesets.Source.sword.Moves.dive_throw)
	local frame = move.Keys[4]
	local carry = move_edit.Unlink(move, {Frame = frame, Track = "carry"})
	local grip = {Frame = frame, Track = "grip"}
	T(move_edit.CanLink({carry, grip}))["=="](true)
	T(move_edit.CanLink({carry}))["=="](false)
	local count = #move.Keys
	local linked = move_edit.Link(move, {carry, grip})
	T(linked[1].Frame)["=="](linked[2].Frame)
	T(linked[1].Frame.grip ~= nil)["=="](true)
	T(linked[1].Frame.carry ~= nil)["=="](true)
	T(#move.Keys)["=="](count - 1)
	T(move_edit.IsLinked(linked[1]))["=="](true)
	local other

	for _, candidate in ipairs(move.Keys) do
		if candidate ~= linked[1].Frame and candidate.carry ~= nil then
			other = candidate
		end
	end

	T(other ~= nil)["=="](true)
	T(move_edit.CanLink{{Frame = other, Track = "carry"}, linked[1]})["=="](false)
end)

T.Test("frames link to a pose block by its arrive or depart time and follow it", function()
	local move = {
		Duration = 1.4,
		Overlays = {{0.1, 0.6, "thrust_windup", FadeIn = 0.14, FadeOut = 0.14, Id = "x"}},
		Keys = {},
	}
	local overlay = move.Overlays[1]
	local frame = move_edit.AddTrackKey(move, "grip", 0.55, {1})
	move_edit.LinkFrame(move, {}, frame, overlay)
	T(frame.Block)["=="]("x")
	T(frame.Edge)["=="]("depart")
	T(frame[1])["~"](0.5, 1e-9)
	T(move_edit.GetBlock(move, frame))["=="](overlay)
	overlay[2] = 0.8
	movesets.ResolveClipLinks(move, {})
	T(frame[1])["~"](0.7, 1e-9)
	T(move_edit.IsLinked{Frame = frame, Track = "grip"})["=="](true)
	local row = find_row(move_edit.Rows(move, {}), "grip")
	T(row.Keys[1].Link)["=="](overlay)
	move_edit.UnlinkFrame(frame)
	T(frame.Block)["=="](nil)
	move_edit.LinkFrame(move, {}, frame, overlay)
	move_edit.RemoveEntry(move, "Overlays", overlay)
	T(frame.Block)["=="](nil)
end)

T.Test("a pose block splits in two and its linked departure keys follow the second half", function()
	local move = {
		Duration = 1.4,
		Overlays = {{0.1, 0.9, "thrust", FadeOut = 0.14, Id = "x"}},
		Keys = {},
	}
	local overlay = move.Overlays[1]
	local frame = move_edit.AddTrackKey(move, "grip", 0.85, {1})
	move_edit.LinkFrame(move, {}, frame, overlay)
	T(frame.Edge)["=="]("depart")
	local right = move_edit.SplitClip(move, "Overlays", overlay, 0.5, nil)
	T(overlay[2])["=="](0.5)
	T(right[1])["=="](0.5)
	T(right[2])["=="](0.9)
	T(right.FadeOut)["=="](0.14)
	T(overlay.FadeOut)["=="](nil)
	T(right.Id ~= overlay.Id)["=="](true)
	T(frame.Block)["=="](right.Id)
	T(#move.Overlays)["=="](2)
end)

T.Test("shots and faces are rows of entries that can be added, moved and removed", function()
	local move = table.copy(movesets.Source.sword.Moves.verdict)
	local rows = move_edit.Rows(move, {})
	T(#find_row(rows, "shots").Keys)["=="](#move.Shots)
	T(#find_row(rows, "faces").Keys)["=="](#move.Faces)
	T(find_row(rows, "shots").Keys[1].Entry)["=="](move.Shots[1])
	local plain = table.copy(movesets.Source.sword.Moves.light_1)
	local entry = move_edit.AddEntry(plain, "Shots", 0.2, {"hero_low"})
	T(plain.Shots[1])["=="](entry)
	T(entry[1])["=="](0.2)
	local face = move_edit.AddEntry(plain, "Faces", 0.1, {"fury"})
	local key = {Entry = entry, List = "Shots"}
	local grabbed = move_edit.Grab{key, {Entry = face, List = "Faces"}}
	move_edit.Transform(plain, grabbed, 0, 1, 0.3, 0.005)
	T(math.abs(entry[1] - 0.5))["<"](0.006)
	T(math.abs(face[1] - 0.4))["<"](0.006)
	T(move_edit.IsLinked(key))["=="](false)
	T(move_edit.CanLink{key, {Entry = face, List = "Faces"}})["=="](false)
	move_edit.RemoveKey(plain, key)
	T(plain.Shots)["=="](nil)
end)

T.Test("locks are rows of ranges that move and scale with their length and validate in order", function()
	local data = table.copy(movesets.Source.sword)
	local move = data.Moves.light_1
	local lock = move_edit.AddEntry(move, "Locks", 0.2, {0.3})
	T(find_row(move_edit.Rows(move, {}), "locks").Keys[1].Until)["=="](0.3)
	local grabbed = move_edit.Grab{{Entry = lock, List = "Locks"}}
	move_edit.Transform(move, grabbed, 0.2, 2, 0, 0.005)
	T(lock[1])["=="](0.2)
	T(math.abs(lock[2] - 0.4))["<"](0.006)
	T(pcall(movesets.Validate, "sword", data))["=="](true)
	lock[2] = 0.1
	T(pcall(movesets.Validate, "sword", data))["=="](false)
	lock[2] = 0.4
	T(movesets.IsLocking({Locks = {lock}}, 0.3))["=="](true)
	T(movesets.IsLocking({Locks = {lock}}, 0.5))["=="](false)
end)

T.Test("a clip move shows strike and cast rows instead of the weapon event rows", function()
	local move = {
		Clips = {{0, 1, "attackA"}},
		Duration = 1,
		Keys = {},
		Events = {{At = 0.5, Type = "strike", Damage = 10, Range = 2}},
	}
	local rows = move_edit.Rows(move, {})
	T(#find_row(rows, "strike").Keys)["=="](1)
	T(find_row(rows, "cast") ~= nil)["=="](true)
	T(find_row(rows, "hit"))["=="](nil)
	local weapon_rows = move_edit.Rows(table.copy(movesets.Source.sword.Moves.light_1), movesets.Source.sword)
	T(find_row(weapon_rows, "hit") ~= nil)["=="](true)
	T(find_row(weapon_rows, "strike"))["=="](nil)
	local event = move_edit.AddEvent(move, "cast", 0.2)
	T(event.Element)["=="]("fire")
	T(move_edit.GetEventFields("cast")[2].String)["=="](true)
end)

T.Test("clips are block rows that carry their trim, move with their length and sort with the move", function()
	local move = {Duration = 2, Keys = {}, Clips = {{0, 0.5, "a"}, {0.5, 1, "b", In = 0.2}}}
	local rows = move_edit.Rows(move, {}, |name|->{Values = {0, 1}, Duration = 2})
	local keys = find_row(rows, "clips").Keys
	T(rows[1].Name)["=="]("clips")
	T(#keys)["=="](2)
	T(keys[2].Block)["=="](true)
	T(keys[2].Until)["=="](1)
	T(keys[2].Wave.From)["=="](0.1)
	T(keys[2].Wave.To)["=="](1)
	local grabbed = move_edit.Grab{{Entry = move.Clips[1], List = "Clips"}}
	move_edit.Transform(move, grabbed, 0, 1, 0.1, 0.005)
	T(math.abs(move.Clips[1][1] - 0.1))["<"](0.006)
	T(math.abs(move.Clips[1][2] - 0.6))["<"](0.006)
	local added = move_edit.AddEntry(move, "Clips", 0.9, {1, "c"})
	T(move.Clips[3])["=="](added)
	move_edit.RemoveKey(move, {Entry = added, List = "Clips"})
	T(#move.Clips)["=="](2)
end)

T.Test("dragging a clip block past its neighbours reorders them and keeps every block clear of the others", function()
	local list = {{0, 0.3, "a"}, {0.3, 0.6, "b"}, {0.6, 1, "c"}}
	local c = list[3]
	move_edit.PlaceBlock(list, c, 0)
	T(list[1])["=="](c)
	T(c[1])["=="](0)
	T(math.abs(c[2] - 0.4))["<"](1e-9)
	T(math.abs(list[2][1] - 0.4))["<"](1e-9)
	T(math.abs(list[3][2] - 1))["<"](1e-9)

	for i = 2, #list do
		T(list[i][1] >= list[i - 1][2] - 1e-9)["=="](true)
	end

	local a = list[2]
	move_edit.PlaceBlock(list, a, 0.9)
	T(a[2] <= 1)["=="](true)
	T(list[3])["=="](a)
end)

T.Test("scaling or moving a group of clips keeps their ends snapped together so the move stays valid", function()
	import("lua/npcs.lua")
	local data = table.copy(movesets.Source.npc_zombie)
	local move = data.Moves.frenzy
	local keys = {}

	for _, clip in ipairs(move.Clips) do
		keys[#keys + 1] = {Entry = clip, List = "Clips"}
	end

	local grabbed = move_edit.Grab(keys)

	for _, scale in ipairs{0.5, 0.83, 0.37, 1} do
		move_edit.Transform(move, grabbed, 0, scale, 0, 0.005)
		T(pcall(movesets.Validate, "npc_zombie", data))["=="](true)
	end
end)

T.Test("a clip splits in two with the trim carried over and its linked strikes follow their half", function()
	local move = {
		Duration = 2,
		Keys = {},
		Clips = {{0, 1, "a", Id = "c1", Out = 4}},
		Events = {
			{At = 0.25, Type = "strike", Damage = 1, Range = 1},
			{At = 0.75, Type = "strike", Damage = 1, Range = 1},
		},
	}
	T(move_edit.LinkEvent(move, move.Events[1], |name|->4))["=="](true)
	T(move_edit.LinkEvent(move, move.Events[2], |name|->4))["=="](true)
	T(move.Events[1].Time)["=="](1)
	T(move.Events[2].Time)["=="](3)
	local right = move_edit.SplitClip(move, "Clips", move.Clips[1], 0.5, 4)
	T(move.Clips[1][2])["=="](0.5)
	T(move.Clips[1].Out)["=="](2)
	T(right[1])["=="](0.5)
	T(right.In)["=="](2)
	T(right.Out)["=="](4)
	T(move.Events[1].Clip)["=="]("c1")
	T(move.Events[2].Clip)["=="](right.Id)
	movesets.ResolveClipLinks(move)
	T(math.abs(move.Events[1].At - 0.25))["<"](1e-9)
	T(math.abs(move.Events[2].At - 0.75))["<"](1e-9)
end)

T.Test("a strike linked to a clip keeps its place in the clip when the clip moves or stretches", function()
	local move = {
		Duration = 2,
		Keys = {},
		Clips = {{0.2, 0.6, "a", Id = "c1", Out = 4}},
		Events = {{At = 0.4, Type = "strike", Damage = 1, Range = 1}},
	}
	T(move_edit.LinkEvent(move, move.Events[1], |name|->4))["=="](true)
	local time = move.Events[1].Time
	T(math.abs(time - 2))["<"](1e-9)
	move.Clips[1][1], move.Clips[1][2] = 0.3, 0.9
	movesets.ResolveClipLinks(move)
	T(math.abs(move.Events[1].At - 0.6))["<"](1e-9)
	move.Clips[1].In = 1
	movesets.ResolveClipLinks(move)
	T(move.Events[1].At >= 0.3 and move.Events[1].At <= 0.9)["=="](true)
	move_edit.UnlinkEvent(move.Events[1])
	T(move.Events[1].Clip)["=="](nil)
end)

T.Test("a clip dragged partly onto its neighbour crossfades with it and one dragged further swaps places", function()
	local list = {{0, 0.4, "a"}, {0.4, 0.8, "b"}}
	local b = list[2]
	T(move_edit.PlaceBlock(list, b, 0.3, true))["=="](true)
	T(math.abs(b[1] - 0.3))["<"](1e-9)
	T(math.abs(list[1][2] - 0.4))["<"](1e-9)
	move_edit.PlaceBlock(list, b, 0.25, true)
	T(math.abs(b[1] - 0.25))["<"](1e-9)
	T(list[1][3])["=="]("a")
	T(math.abs(list[1][1]))["<"](1e-9)
	move_edit.PlaceBlock(list, b, -0.2, true)
	T(list[1])["=="](b)
	T(b[1])["=="](0)
	T(list[2][1] >= b[2] - 0.2 - 1e-9)["=="](true)
	T(list[2][1] < b[2])["=="](true)
end)

T.Test("the move editor marks moves that differ from the file, steps between moves and reverts one", function()
	local data_history = import("lua/data_history.lua")
	local move_editor = import("lua/jrpg/move_editor.lua")
	local data = movesets.ReadFile("sword")
	local session = {
		SetName = "sword",
		Data = data,
		Baseline = movesets.ReadFile("sword"),
		History = data_history.New(data),
		Selected = {},
		SelectId = 0,
		MoveName = "light_1",
	}
	T(#move_editor.GetDirtyNames(session))["=="](0)
	local duration = data.Moves.light_1.Duration
	data.Moves.light_1.Duration = duration + 0.1
	T(move_editor.GetDirtyNames(session)[1])["=="]("light_1")
	move_editor.StepMove(session, 1)
	T(session.MoveName)["~="]("light_1")
	move_editor.StepMove(session, -1)
	T(session.MoveName)["=="]("light_1")
	move_editor.RevertMove(session, "light_1")
	T(session.Data.Moves.light_1.Duration)["=="](duration)
	T(#move_editor.GetDirtyNames(session))["=="](0)
	T(movesets.Get("sword").Moves.light_1.Duration)["=="](duration)
end)

T.Test("ghost phases are spread over the whole move, around the playhead or at the keys", function()
	local move_editor = import("lua/jrpg/move_editor.lua")
	local data = movesets.ReadFile("sword")
	local session = {
		Data = data,
		MoveName = "light_1",
		Phase = 0.5,
		Selected = {},
		GhostMode = "whole move",
		GhostSource = "evenly spaced",
		GhostCount = 5,
		GhostWindow = 0.2,
	}
	local phases = move_editor.GetGhostPhases(session)
	T(#phases)["=="](5)
	T(phases[1])["=="](0)
	T(phases[5])["=="](1)
	session.GhostMode = "around playhead"
	phases = move_editor.GetGhostPhases(session)

	for _, phase in ipairs(phases) do
		T(phase >= 0.3 - 1e-6 and phase <= 0.7 + 1e-6 and math.abs(phase - 0.5) > 0.005)["=="](true)
	end

	session.GhostMode = "selection"
	T(#move_editor.GetGhostPhases(session))["=="](0)
	session.GhostMode = "whole move"
	session.GhostSource = "one per key"
	phases = move_editor.GetGhostPhases(session)
	T(#phases > 0 and #phases <= 12)["=="](true)

	for i = 2, #phases do
		T(phases[i] > phases[i - 1])["=="](true)
	end
end)

T.Test("a pose block is only added where fewer than two blocks already cover the range", function()
	local move = {
		Duration = 1,
		Overlays = {{0, 0.5, "a"}, {0.3, 0.8, "b"}},
		Keys = {},
	}
	T(move_edit.AddOverlay(move, 0.4, "c"))["=="](nil)
	local added = move_edit.AddOverlay(move, 0.85, "c")
	T(added ~= nil)["=="](true)
	T(added[1])["=="](0.85)
	T(added[2] <= 1)["=="](true)
	T(#move.Overlays)["=="](3)
end)

T.Test("merging pose blocks into one pose animation keeps the curves and linked keys, and splitting restores them", function()
	local keyframes = import("lua/keyframes.lua")
	local animations = import("lua/animations.lua")

	local function build()
		return {
			Duration = 1.2,
			Overlays = {
				{0, 0.4, "windup_right", FadeIn = 0.18, Ease = "out"},
				{0.2, 0.7, "cut_left", Ease = "in", Id = "b"},
				{0.45, 1, "windup_right", FadeOut = 0.24},
			},
			Keys = {{0.5, body = {0, 0, 0, 0, 0, 0}, Block = "b", Edge = "depart"}},
		}
	end

	local function compare(a, b)
		local out_a, out_b = {0, 0}, {0, 0}

		for i = 0, 200 do
			animations.SampleKeys(a.AimKeys, i / 200, out_a, 2)
			animations.SampleKeys(b.AimKeys, i / 200, out_b, 2)
			T(math.abs(out_a[1] - out_b[1]))["<"](0.01)
			T(math.abs(out_a[2] - out_b[2]))["<"](0.01)
		end
	end

	local reference = build()
	movesets.ResolveClipLinks(reference, {})
	local before = keyframes.Compile(table.copy(reference))
	local move, data = build(), {}
	movesets.ResolveClipLinks(move, data.Gestures)
	local merged = move_edit.MergeOverlays(move, data, 1, 3, "swing")
	T(#move.Overlays)["=="](1)
	T(merged[3])["=="]("swing")
	T(data.Gestures.swing.Duration)["~"](1.2, 1e-3)
	T(#data.Gestures.swing.Keys >= 4)["=="](true)
	T(move.Keys[1].Edge)["=="](nil)
	T(move.Keys[1].Time ~= nil)["=="](true)
	T(move_edit.CanMerge(move, data, 1, 1))["=="](false)
	movesets.ResolveClipLinks(move, data.Gestures)
	T(move.Keys[1][1])["~"](reference.Keys[1][1], 2e-3)
	compare(before, keyframes.Compile(table.copy(move), nil, data.Gestures))
	merged.In = 0.3
	movesets.ResolveClipLinks(move, data.Gestures)
	T(move.Keys[1][1] < reference.Keys[1][1])["=="](true)
	merged.In = nil
	local blocks = move_edit.SplitGesture(move, data, merged)
	T(#blocks)["=="](3)
	T(data.Gestures.swing)["=="](nil)
	movesets.ResolveClipLinks(move, data.Gestures)
	T(move.Keys[1][1])["~"](reference.Keys[1][1], 2e-3)
	compare(before, keyframes.Compile(table.copy(move), nil, {}))
end)

T.Test("pose animation keys are added and removed and the gesture stays valid", function()
	local move = {Duration = 1, Overlays = {{0, 1, "swing"}}, Keys = {}}
	local data = {
		Gestures = {
			swing = {Duration = 1, Keys = {{0, "windup_right"}, {1, "cut_left", ease = "in"}}},
		},
	}
	local key = move_edit.AddGestureKey(move, data, move.Overlays[1], 0.5)
	T(key[1])["~"](0.5, 1e-9)
	T(#data.Gestures.swing.Keys)["=="](3)
	T(move_edit.AddGestureKey(move, data, move.Overlays[1], 0.5))["=="](nil)
	T(move_edit.RemoveGestureKey(data, move.Overlays[1], key))["=="](true)
	T(#data.Gestures.swing.Keys)["=="](2)
	T(#move_edit.GetGestureMarks(move, data, move.Overlays[1]))["=="](2)
	local def = {Poses = {}, Gestures = data.Gestures, Moves = {a = move}}
	T(pcall(movesets.Validate, "test", def))["=="](true)
	data.Gestures.swing.Keys[2][1] = 2
	T(pcall(movesets.Validate, "test", def))["=="](false)
end)

T.Test("a pose animation shows its activity as a wave that is flat while it holds and high while it moves", function()
	local data = {
		Gestures = {
			swing = {
				Duration = 1,
				Keys = {
					{0, "windup_right"},
					{0.4, "windup_right"},
					{0.6, "cut_left", ease = "linear"},
					{1, "cut_left"},
				},
			},
		},
	}
	local values = move_edit.GetGestureActivity(data, "swing", 101)
	T(#values)["=="](101)
	T(values[10])["<"](0.05)
	T(values[50])[">"](0.9)
	T(values[90])["<"](0.05)
	local move = {Duration = 1, Overlays = {{0, 1, "swing"}}, Keys = {}}
	local row = find_row(
		move_edit.Rows(move, data, nil, |name|->move_edit.GetGestureActivity(data, name, 32)),
		"poses"
	)
	T(#row.Keys[1].Wave.Values)["=="](32)
	T(row.Keys[1].Wave.To)["=="](1)
end)
