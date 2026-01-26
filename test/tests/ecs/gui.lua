local T = require("test.environment")
local prototype = require("prototype")
local ecs = require("ecs.ecs")
local transform_2d = require("ecs.components.2d.transform")
local rect_2d = require("ecs.components.2d.rect")
local mouse_input_2d = require("ecs.components.2d.mouse_input")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")

T.Test("ecs gui basic", function()
	local world = ecs.Get2DWorld()
	local entity = ecs.CreateEntity("gui_element", world)
	local tr = entity:AddComponent(transform_2d)
	tr:SetPosition(Vec2(100, 100))
	tr:SetSize(Vec2(200, 100))
	local rect = entity:AddComponent(rect_2d)
	rect:SetColor(Color(1, 0, 0, 1))
	local mouse = entity:AddComponent(mouse_input_2d)
	T(entity:HasComponent("transform_2d"))["=="](true)
	T(entity:HasComponent("rect_2d"))["=="](true)
	T(entity:HasComponent("mouse_input_2d"))["=="](true)
	-- Test hovering
	T(entity.gui_element_2d:IsHovered(Vec2(150, 150)))["=="](true)
	T(entity.gui_element_2d:IsHovered(Vec2(50, 50)))["=="](false)
	entity:Remove()
end)

T.Test("ecs gui parenting", function()
	local world = ecs.Get2DWorld()
	local parent = ecs.CreateEntity("parent", world)
	local ptr = parent:AddComponent(transform_2d)
	ptr:SetPosition(Vec2(100, 100))
	ptr:SetSize(Vec2(200, 200))
	parent:AddComponent(rect_2d)
	local child = ecs.CreateEntity("child", parent)
	local ctr = child:AddComponent(transform_2d)
	ctr:SetPosition(Vec2(50, 50))
	ctr:SetSize(Vec2(50, 50))
	child:AddComponent(rect_2d)
	local world_rect = child:GetComponent("rect_2d")
	-- child is at 100+50, 100+50 = 150, 150
	-- size is 50, 50, so it goes from 150 to 200.
	T(child.gui_element_2d:IsHovered(Vec2(175, 175)))["=="](true)
	T(child.gui_element_2d:IsHovered(Vec2(125, 125)))["=="](false)
	parent:Remove()
end)

T.Test("ecs system start/stop", function()
	local world = ecs.Get2DWorld()
	local start_called = 0
	local stop_called = 0
	local test_component = {
		Component = prototype.CreateTemplate("test_sys"),
		StartSystem = function()
			start_called = start_called + 1
		end,
		StopSystem = function()
			stop_called = stop_called + 1
		end,
	}
	test_component.Component.ComponentName = "test_sys"
	test_component.Component:Register()
	local ent1 = ecs.CreateEntity("ent1", world)
	ent1:AddComponent(test_component)
	T(start_called)["=="](1)
	T(stop_called)["=="](0)
	local ent2 = ecs.CreateEntity("ent2", world)
	ent2:AddComponent(test_component)
	T(start_called)["=="](1) -- Should not be called again
	T(stop_called)["=="](0)
	ent1:Remove()
	T(stop_called)["=="](0) -- One remains
	ent2:Remove()
	T(stop_called)["=="](1) -- Last one removed
end)
