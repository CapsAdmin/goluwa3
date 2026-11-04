local T = import("test/environment.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Timeline = import("goluwa/render2d/ui/widgets/timeline.lua")

T.Test2D("timeline scrubs, selects, drags, adds and zooms", function()
	local log = {}
	local rows = {
		{Name = "a", Keys = {{Time = 0.25}, {Time = 0.5, Until = 0.6}, {Time = 0.75}}},
		{Name = "b", Keys = {}},
	}
	local timeline = Timeline{
		Rows = rows,
		Size = Vec2(1096, 200),
		LabelWidth = 96,
		AxisPadding = 0,
		RulerHeight = 20,
		RowHeight = 20,
		OnScrub = function(time)
			log.scrub = time
		end,
		OnSelect = function(row, index)
			log.row, log.index = row, index
		end,
		OnKeyMove = function(row, index, time)
			rows[row].Keys[index].Time = time
			log.moved = time
		end,
		OnKeyDrop = function(row, index)
			log.dropped = index
		end,
		OnKeyAdd = function(row, time)
			log.added = {row, time}
		end,
	}
	timeline.transform:SetSize(Vec2(1096, 200))
	local x = |time|->96 + time * 1000
	timeline:OnMouseInput("button_1", true, Vec2(x(0.4), 10))
	T(log.scrub)["=="](0.4)
	timeline:OnMouseInput("button_1", false, Vec2(x(0.4), 10))
	timeline:OnMouseInput("button_1", true, Vec2(x(0.5), 30))
	T(log.row)["=="](1)
	T(log.index)["=="](2)
	timeline.transform:SetPosition(Vec2(0, 0))
	timeline:OnGlobalMouseMove(Vec2(x(0.55), 30))
	T(log.moved)["=="](0.55)
	timeline:OnGlobalMouseMove(Vec2(x(0.9), 30))
	T(log.moved)["=="](0.9)
	timeline:OnGlobalMouseInput("button_1", false)
	T(log.dropped)["=="](2)
	timeline:OnMouseInput("button_1", true, Vec2(x(0.3), 50))
	timeline:OnMouseInput("button_1", false, Vec2(x(0.3), 50))
	timeline:OnMouseInput("button_1", true, Vec2(x(0.3), 50))
	T(log.added[1])["=="](2)
	T(log.added[2])["=="](0.3)
	timeline:OnMouseInput("button_1", false, Vec2(x(0.3), 50))
	timeline:OnMouseInput("mwheel_up", true, Vec2(x(0.5), 50))
	local from, to = timeline:GetViewRange()
	T(to - from)["<"](1)
	T(from)["<="](0.5)
	T(to)[">="](0.5)
	timeline:ResetView()
	from, to = timeline:GetViewRange()
	T(from)["=="](0)
	T(to)["=="](1)
	timeline:Remove()
end)

T.Test2D("timeline marquee selects keys, moves them together and scales the bounds", function()
	local log = {}
	local rows = {
		{Name = "a", Keys = {{Time = 0.2}, {Time = 0.4}, {Time = 0.9}}},
		{Name = "b", Keys = {{Time = 0.3}}},
	}
	local timeline
	timeline = Timeline{
		Rows = rows,
		Size = Vec2(1096, 200),
		LabelWidth = 96,
		AxisPadding = 0,
		RulerHeight = 20,
		RowHeight = 20,
		OnSelectKeys = function(selection)
			log.selection = selection
			timeline:SetSelection(selection)
		end,
		OnKeysTransform = function(anchor, scale, offset, first)
			log.transform = {anchor, scale, offset, first}
		end,
		OnKeysDrop = function()
			log.dropped = true
		end,
		OnKeyMenu = function(row, index)
			log.menu = {row, index}
		end,
	}
	timeline.transform:SetSize(Vec2(1096, 200))
	timeline.transform:SetPosition(Vec2(0, 0))
	local x = |time|->96 + time * 1000
	timeline:OnMouseInput("button_1", true, Vec2(x(0.1), 25))
	timeline:OnGlobalMouseMove(Vec2(x(0.5), 55))
	T(#log.selection)["=="](3)
	timeline:OnGlobalMouseInput("button_1", false)
	T(#timeline:GetSelection())["=="](3)
	timeline:OnMouseInput("button_1", true, Vec2(x(0.4), 30))
	timeline:OnGlobalMouseMove(Vec2(x(0.5), 30))
	T(log.transform[1])["=="](0)
	T(log.transform[2])["=="](1)
	T(math.abs(log.transform[3] - 0.1))["<"](0.0001)
	T(log.transform[4])["=="](true)
	timeline:OnGlobalMouseInput("button_1", false)
	T(log.dropped)["=="](true)
	timeline:OnMouseMove(Vec2(x(0.4), 16))
	T(timeline.mouse_input:GetCursor())["=="]("horizontal_resize")
	timeline:OnMouseMove(Vec2(x(0.3), 16))
	T(timeline.mouse_input:GetCursor())["=="]("arrow")
	timeline:OnMouseInput("button_1", true, Vec2(x(0.4), 16))
	timeline:OnGlobalMouseMove(Vec2(x(0.5), 16))
	T(log.transform[1])["=="](0.2)
	T(math.abs(log.transform[2] - 1.5))["<"](0.0001)
	timeline:OnGlobalMouseInput("button_1", false)
	rows[3] = {Name = "+", Button = true, Keys = {}}
	timeline.OnRowAction = function(row)
		log.action = row
	end
	timeline:OnMouseInput("button_1", true, Vec2(10, 70))
	T(log.action)["=="](3)
	timeline:OnMouseInput("button_1", false, Vec2(10, 70))
	timeline:OnMouseInput("button_2", true, Vec2(x(0.4), 30))
	T(log.menu[1])["=="](1)
	T(log.menu[2])["=="](2)
	timeline:Remove()
end)

T.Test2D("timeline keys with an until have an end handle to resize and a bar that selects them", function()
	local log = {}
	local rows = {{Name = "a", Keys = {{Time = 0.2, Until = 0.4}, {Time = 0.7}}}}
	local timeline = Timeline{
		Rows = rows,
		Size = Vec2(1096, 100),
		LabelWidth = 96,
		AxisPadding = 0,
		RulerHeight = 20,
		RowHeight = 20,
		OnSelect = function(row, index)
			log.selected = {row, index}
		end,
		OnKeyResize = function(row, index, time)
			log.resized = time
			rows[row].Keys[index].Until = time
		end,
		OnKeyMove = function(row, index, time)
			log.moved = time
		end,
	}
	timeline.transform:SetSize(Vec2(1096, 100))
	timeline.transform:SetPosition(Vec2(0, 0))
	local x = |time|->96 + time * 1000
	local row, index, part = timeline:key_at(Vec2(x(0.3), 30))
	T(index)["=="](1)
	T(part)["=="]("bar")
	row, index, part = timeline:key_at(Vec2(x(0.4), 30))
	T(part)["=="]("end")
	timeline:OnMouseInput("button_1", true, Vec2(x(0.4), 30))
	T(log.selected[2])["=="](1)
	timeline:OnGlobalMouseMove(Vec2(x(0.55), 30))
	T(log.resized)["=="](0.55)
	timeline:OnGlobalMouseMove(Vec2(x(0.9), 30))
	T(log.resized)["=="](0.7 - timeline:GetSnap())
	timeline:OnGlobalMouseMove(Vec2(x(0.1), 30))
	T(log.resized)["=="](0.2 + timeline:GetSnap())
	timeline:OnGlobalMouseInput("button_1", false)
	rows[1].Keys[1].Until = 0.4
	log.moved = nil
	timeline:OnMouseInput("button_1", true, Vec2(x(0.3), 30))
	T(log.selected[2])["=="](1)
	timeline:OnGlobalMouseMove(Vec2(x(0.35), 30))
	T(log.moved)["~"](0.25, 0.006)
	timeline:Remove()
end)

T.Test2D("timeline block keys trim from either edge and move by their body", function()
	local log = {}
	local rows = {
		{
			Name = "clips",
			Keys = {
				{Time = 0.1, Until = 0.4, Block = true},
				{Time = 0.5, Until = 0.8, Block = true},
			},
		},
	}
	local timeline = Timeline{
		Rows = rows,
		Size = Vec2(1096, 100),
		LabelWidth = 96,
		AxisPadding = 0,
		RulerHeight = 20,
		RowHeight = 20,
		OnKeyTrim = function(row, index, edge, time)
			log.trim = {edge, time}
			rows[row].Keys[index][edge == "left" and "Time" or "Until"] = time
		end,
		OnKeyMove = function(row, index, time)
			log.moved = time
		end,
	}
	timeline.transform:SetSize(Vec2(1096, 100))
	timeline.transform:SetPosition(Vec2(0, 0))
	local x = |time|->96 + time * 1000
	local _, _, part = timeline:key_at(Vec2(x(0.1), 30))
	T(part)["=="]("left")
	_, _, part = timeline:key_at(Vec2(x(0.4), 30))
	T(part)["=="]("right")
	_, _, part = timeline:key_at(Vec2(x(0.25), 30))
	T(part)["=="]("bar")
	timeline:OnMouseInput("button_1", true, Vec2(x(0.4), 30))
	timeline:OnGlobalMouseMove(Vec2(x(0.7), 30))
	T(log.trim[1])["=="]("right")
	T(log.trim[2])["~"](0.7, 1e-9)
	timeline:OnGlobalMouseMove(Vec2(x(0.05), 30))
	T(log.trim[2])["=="](0.1 + 0.01)
	timeline:OnGlobalMouseInput("button_1", false)
	rows[1].Keys[1].Until = 0.4
	timeline:OnMouseInput("button_1", true, Vec2(x(0.25), 30))
	timeline:OnGlobalMouseMove(Vec2(x(0.9), 30))
	T(math.abs(log.moved - 0.7))["<"](0.006)
	timeline:OnGlobalMouseInput("button_1", false)
	timeline:Remove()
end)

T.Test2D("timeline block keys slip their content with alt and pass the clicked time to the key menu", function()
	local log = {}
	local rows = {
		{
			Name = "clips",
			Keys = {
				{
					Time = 0.2,
					Until = 0.6,
					Block = true,
					Wave = {Values = {0, 1, 0}, From = 0.25, To = 0.75},
				},
			},
		},
	}
	local timeline = Timeline{
		Rows = rows,
		Size = Vec2(1096, 100),
		LabelWidth = 96,
		AxisPadding = 0,
		RulerHeight = 20,
		RowHeight = 20,
		OnKeySlip = function(row, index, delta, first)
			log.slip = {delta, first}
		end,
		OnKeyMenu = function(row, index, time)
			log.menu_time = time
		end,
	}
	timeline.transform:SetSize(Vec2(1096, 100))
	timeline.transform:SetPosition(Vec2(0, 0))
	local x = |time|->96 + time * 1000
	timeline:OnMouseInput("button_2", true, Vec2(x(0.4), 30))
	T(math.abs(log.menu_time - 0.4))["<"](0.006)
	local input = import("goluwa/input.lua")
	local was_down = input.IsAltDown
	input.IsAltDown = function()
		return true
	end
	timeline:OnMouseInput("button_1", true, Vec2(x(0.4), 30))
	timeline:OnGlobalMouseMove(Vec2(x(0.5), 30))
	T(math.abs(log.slip[1] - 0.1))["<"](0.006)
	T(log.slip[2])["=="](true)
	timeline:OnGlobalMouseMove(Vec2(x(0.55), 30))
	T(log.slip[2])["=="](false)
	timeline:OnGlobalMouseInput("button_1", false)
	input.IsAltDown = was_down
	timeline:Remove()
end)

T.Test2D("timeline picks the closest edge when block keys touch", function()
	local rows = {
		{
			Name = "clips",
			Keys = {
				{Time = 0.1, Until = 0.3, Block = true},
				{Time = 0.3, Until = 0.6, Block = true},
			},
		},
	}
	local timeline = Timeline{
		Rows = rows,
		Size = Vec2(1096, 100),
		LabelWidth = 96,
		AxisPadding = 0,
		RulerHeight = 20,
		RowHeight = 20,
	}
	timeline.transform:SetSize(Vec2(1096, 100))
	timeline.transform:SetPosition(Vec2(0, 0))
	local x = |time|->96 + time * 1000
	local _, index, part = timeline:key_at(Vec2(x(0.3) - 3, 30))
	T(index)["=="](1)
	T(part)["=="]("right")
	_, index, part = timeline:key_at(Vec2(x(0.3) + 3, 30))
	T(index)["=="](2)
	T(part)["=="]("left")
	_, index, part = timeline:key_at(Vec2(x(0.2), 30))
	T(index)["=="](1)
	T(part)["=="]("bar")
	timeline:Remove()
end)
