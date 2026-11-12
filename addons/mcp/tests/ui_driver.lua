local T = import("test/environment.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local VirtualGrid = import("goluwa/render2d/ui/elements/virtual_grid.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local event = import("goluwa/event.lua")
local MouseInput = import("goluwa/render2d/ui/components/mouse_input.lua")
local ui_driver = import("addons/mcp/lua/ui_driver.lua")

local function create_world()
	local old_world = Panel.World
	local world = Panel.New{ComponentSet = {"transform", "visual"}}
	world.transform:SetSize(Vec2(512, 512))
	Panel.World = world
	return old_world, world
end

local function settle(world, pnl)
	for _ = 1, 3 do
		pnl.layout:UpdateLayout()
		world.visual:DrawRecursive()
	end
end

T.Test2D("ui driver finds a button by its text and clicks it through the window", function()
	local old_world, world = create_world()
	local clicked = 0
	local button = Button{
		Text = "Press me",
		OnClick = function()
			clicked = clicked + 1
		end,
	}
	button:SetParent(world)
	button.transform:SetPosition(Vec2(100, 100))
	settle(world, button)
	T(ui_driver.FindOne{text = "press me", type = "panel_button"} == button)["=="](true)
	T(ui_driver.Find{text = "press", exact = true}[1] == nil)["=="](true)
	T(pcall(ui_driver.Find, {txt = "press me"}))["=="](false)
	local window = ui_driver.Attach()
	window.ui_driver_position = ui_driver.GetCenter(button)
	event.CallUpdate()
	T(
		MouseInput.GetHoveredObject():ContainsParent(button) or
			MouseInput.GetHoveredObject() == button
	)["=="](true)
	event.Call("MouseInput", "button_1", true)
	event.Call("MouseInput", "button_1", false)
	T(clicked)["=="](1)
	ui_driver.Detach()
	button:Remove()
	Panel.World = old_world
end)

T.Test2D("ui driver targets the cells a virtual grid draws", function()
	local old_world, world = create_world()
	local items = {}

	for i = 1, 50 do
		items[i] = {name = "cell " .. i}
	end

	local grid = VirtualGrid{
		CellWidth = 100,
		ExtraHeight = 20,
		Gap = 10,
		ContentPadding = 10,
		Items = items,
		OnDrawItem = function() end,
	}
	grid:SetParent(world)
	grid.transform:SetSize(Vec2(450, 300))
	settle(world, grid)
	local found = ui_driver.FindOne{item = "cell 2", exact = true}
	T(found.item == items[2])["=="](true)
	T(found.y)["<"](300)
	T(ui_driver.FindItems{item = "cell 40", exact = true}[1] == nil)["=="](true)
	grid:Remove()
	Panel.World = old_world
end)
