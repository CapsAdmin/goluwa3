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
