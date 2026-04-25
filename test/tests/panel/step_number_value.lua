local T = import("test/environment.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")

T.Test2D("step_number_value drag ignores oversized first-frame mouse delta", function()
	local old_world = Panel.World
	local test_world = Panel.New{
		ComponentSet = {"transform", "gui_element"},
	}
	test_world:SetName("TestWorld")
	test_world.transform:SetSize(Vec2(1000, 1000))
	Panel.World = test_world

	local window = system.GetWindow()
	local old_mouse_pos = window:GetMousePosition():Copy()
	local old_mouse_delta = window:GetMouseDelta():Copy()
	local old_mouse_trapped = window:GetMouseTrapped()
	local input = import("goluwa/input.lua")
	local old_is_key_down = input.IsKeyDown
	local StepNumberValue = import("game/addons/gui/lua/ui/elements/step_number_value.lua")
	local control = StepNumberValue{Value = 0}
	input.IsKeyDown = function()
		return false
	end

	local function cleanup()
		if control and control.IsValid and control:IsValid() then control:Remove() end
		if test_world and test_world.IsValid and test_world:IsValid() then test_world:Remove() end
		Panel.World = old_world
		input.IsKeyDown = old_is_key_down
		window:SetMousePosition(old_mouse_pos)
		window:SetMouseDelta(old_mouse_delta)
		window:SetMouseTrapped(old_mouse_trapped)
	end

	local ok, err = xpcall(function()
		control:SetParent(test_world)
		control.transform:SetPosition(Vec2(0, 0))

		window:SetMousePosition(Vec2(10, 10))
		window:SetMouseDelta(Vec2(0, 0))
		event.Call("Update")
		T(control.mouse_input:GetHovered())["=="](true)

		event.Call("MouseInput", "button_1", true)
		window:SetMousePosition(Vec2(10, 15))
		window:SetMouseDelta(Vec2(0, 50))
		event.Call("Update")
		T(control:GetValue())["=="](-0.05)
		T(window:GetMouseTrapped())["=="](true)
		T(window:GetMousePosition())["=="](Vec2(10, 10))

		event.Call("MouseInput", "button_1", false)
		T(window:GetMouseTrapped())["=="](false)
	end, debug.traceback)

	cleanup()

	if not ok then error(err, 0) end
end)

T.Test2D("step_number_value drag does not warp cursor on no-warp backends", function()
	local old_world = Panel.World
	local test_world = Panel.New{
		ComponentSet = {"transform", "gui_element"},
	}
	test_world:SetName("TestWorld")
	test_world.transform:SetSize(Vec2(1000, 1000))
	Panel.World = test_world

	local window = system.GetWindow()
	local old_mouse_pos = window:GetMousePosition():Copy()
	local old_mouse_delta = window:GetMouseDelta():Copy()
	local old_mouse_trapped = window:GetMouseTrapped()
	local old_should_warp = window.ShouldWarpMouseWhenCaptured
	local input = import("goluwa/input.lua")
	local old_is_key_down = input.IsKeyDown
	local StepNumberValue = import("game/addons/gui/lua/ui/elements/step_number_value.lua")
	local control = StepNumberValue{Value = 0}
	input.IsKeyDown = function()
		return false
	end
	window.ShouldWarpMouseWhenCaptured = function()
		return false
	end

	local function cleanup()
		if control and control.IsValid and control:IsValid() then control:Remove() end
		if test_world and test_world.IsValid and test_world:IsValid() then test_world:Remove() end
		Panel.World = old_world
		input.IsKeyDown = old_is_key_down
		window.ShouldWarpMouseWhenCaptured = old_should_warp
		window:SetMousePosition(old_mouse_pos)
		window:SetMouseDelta(old_mouse_delta)
		window:SetMouseTrapped(old_mouse_trapped)
	end

	local ok, err = xpcall(function()
		control:SetParent(test_world)
		control.transform:SetPosition(Vec2(0, 0))

		window:SetMousePosition(Vec2(10, 10))
		window:SetMouseDelta(Vec2(0, 0))
		event.Call("Update")
		T(control.mouse_input:GetHovered())["=="](true)

		event.Call("MouseInput", "button_1", true)
		window:SetMousePosition(Vec2(10, 15))
		window:SetMouseDelta(Vec2(0, 50))
		event.Call("Update")
		T(control:GetValue())["=="](-0.05)
		T(window:GetMouseTrapped())["=="](true)
		T(window:GetMousePosition())["=="](Vec2(10, 15))

		event.Call("MouseInput", "button_1", false)
		T(window:GetMouseTrapped())["=="](false)
		T(window:GetMousePosition())["=="](Vec2(10, 15))
	end, debug.traceback)

	cleanup()

	if not ok then error(err, 0) end
end)