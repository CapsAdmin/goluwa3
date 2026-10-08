local T = import("test/environment.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")

local function create_world()
	local old_world = Panel.World
	local world = Panel.New{ComponentSet = {"transform", "visual"}}
	world:SetName("TestWorld")
	world.transform:SetSize(Vec2(512, 512))
	Panel.World = world
	return old_world, world
end

T.Test2D("scrollable panel with default settings lets a tall child keep its height and shows the scrollbar", function()
	local old_world, world = create_world()
	local panel = ScrollablePanel{}
	local child = Panel.New{
		transform = true,
		layout = {GrowWidth = 1, MinSize = Vec2(0, 1000), MaxSize = Vec2(0, 1000)},
	}
	panel:AddChild(child)
	panel:SetParent(world)
	panel.transform:SetSize(Vec2(200, 300))

	for _ = 1, 3 do
		panel.layout:UpdateLayout()
		world.visual:DrawRecursive()
	end

	T(child.transform:GetHeight())["=="](1000)
	T(panel.Viewport.layout:GetDirection())["=="]("y")
	T(panel.Viewport.layout.content_size.y)["=="](1000)
	T(panel.HandleY.visual:GetVisible())["=="](true)
	panel:Remove()
	Panel.World = old_world
end)

T.Test2D("scrollable panel hides the scrollbar when everything fits", function()
	local old_world, world = create_world()
	local panel = ScrollablePanel{}
	local child = Panel.New{
		transform = true,
		layout = {GrowWidth = 1, MinSize = Vec2(0, 50), MaxSize = Vec2(0, 50)},
	}
	panel:AddChild(child)
	panel:SetParent(world)
	panel.transform:SetSize(Vec2(200, 300))

	for _ = 1, 3 do
		panel.layout:UpdateLayout()
		world.visual:DrawRecursive()
	end

	T(child.transform:GetHeight())["=="](50)
	T(panel.HandleY.visual:GetVisible())["=="](false)
	panel:Remove()
	Panel.World = old_world
end)

T.Test2D("scrollable panel with only ScrollX never shows the vertical scrollbar", function()
	local old_world, world = create_world()
	local panel = ScrollablePanel{ScrollX = true, ScrollY = false}
	local child = Panel.New{
		transform = true,
		layout = {MinSize = Vec2(1000, 50), MaxSize = Vec2(1000, 50)},
	}
	panel:AddChild(child)
	panel:SetParent(world)
	panel.transform:SetSize(Vec2(200, 300))

	for _ = 1, 3 do
		panel.layout:UpdateLayout()
		world.visual:DrawRecursive()
	end

	T(panel.HandleX.visual:GetVisible())["=="](true)
	T(panel.HandleY.visual:GetVisible())["=="](false)
	T(panel.TrackY.visual:GetVisible())["=="](false)
	panel:Remove()
	Panel.World = old_world
end)

T.Test2D("scrollbar auto mode shifts content in big panels and floats over it in small ones", function()
	local old_world, world = create_world()
	local theme = import("goluwa/render2d/ui/theme.lua")
	local threshold = theme.active:GetScrollbarAutoShiftSize()
	local results = {}

	for name, width in pairs{big = threshold + 100, small = threshold - 100} do
		local panel = ScrollablePanel{Padding = Rect(10, 10, 10, 10)}
		panel:AddChild(
			Panel.New{
				transform = true,
				layout = {GrowWidth = 1, MinSize = Vec2(0, 1000), MaxSize = Vec2(0, 1000)},
			}
		)
		panel:SetParent(world)
		panel.transform:SetSize(Vec2(width, 300))

		for _ = 1, 3 do
			panel.layout:UpdateLayout()
			world.visual:DrawRecursive()
		end

		results[name] = {
			reserve = panel.Viewport.layout:GetPadding().w - 10,
			bar_visible = panel.HandleY.visual:GetVisible(),
			track_y = panel.TrackY.transform:GetPosition().y,
			track_right = width - (
					panel.TrackY.transform:GetPosition().x + panel.TrackY.transform:GetWidth()
				),
		}
		panel:Remove()
	end

	local margin = theme.active:GetScrollbarMargin()
	T(results.big.bar_visible)["=="](true)
	T(results.small.bar_visible)["=="](true)
	T(results.big.reserve)[">"](0)
	T(results.small.reserve)["=="](0)
	T(results.big.track_y)["=="](margin)
	T(results.big.track_right)["=="](margin)
	Panel.World = old_world
end)

T.Test2D("explicit shift modes ignore the panel size", function()
	local old_world, world = create_world()
	local panel = ScrollablePanel{ScrollbarShiftMode = "no_shift"}
	panel:AddChild(
		Panel.New{
			transform = true,
			layout = {GrowWidth = 1, MinSize = Vec2(0, 1000), MaxSize = Vec2(0, 1000)},
		}
	)
	panel:SetParent(world)
	panel.transform:SetSize(Vec2(500, 300))

	for _ = 1, 3 do
		panel.layout:UpdateLayout()
		world.visual:DrawRecursive()
	end

	T(panel.Viewport.layout:GetPadding().w)["=="](0)
	panel:Remove()
	panel = ScrollablePanel{ScrollbarShiftMode = "always_shift"}
	panel:SetParent(world)
	panel.transform:SetSize(Vec2(100, 300))

	for _ = 1, 3 do
		panel.layout:UpdateLayout()
		world.visual:DrawRecursive()
	end

	T(panel.Viewport.layout:GetPadding().w)[">"](0)
	panel:Remove()
	Panel.World = old_world
end)
