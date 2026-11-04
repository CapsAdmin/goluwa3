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
	T(log.moved)["=="](0.75 - timeline:GetSnap())
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
	timeline:OnMouseInput("button_2", true, Vec2(x(0.4), 30))
	T(log.menu[1])["=="](1)
	T(log.menu[2])["=="](2)
	timeline:Remove()
end)
