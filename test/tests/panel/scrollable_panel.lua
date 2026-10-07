local T = import("test/environment.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local Vec2 = import("goluwa/structs/vec2.lua")

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
