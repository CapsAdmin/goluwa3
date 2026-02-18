local T = require("test.environment")
local Panel = require("ecs.panel")
local Vec2 = require("structs.vec2")
local window = require("window")
local event = require("event")
local prototype = require("prototype")

T.Test("mouse input event order (local and global)", function()
	local old_world = Panel.World
	Panel.World = Panel.New({
		ComponentSet = {"transform", "gui_element"},
	})
	Panel.World:SetName("TestWorld")
	Panel.World.transform:SetSize(Vec2(1000, 1000))
	local call_stack = {}

	local function create_panel(name, pos, size)
		local pnl = Panel.New(
			{
				Parent = Panel.World,
				Name = name,
				transform = true,
				gui_element = true,
				mouse_input = true,
			}
		)
		pnl.transform:SetPosition(pos or Vec2(0, 0))
		pnl.transform:SetSize(size or Vec2(100, 100))

		pnl:AddLocalListener("OnMouseInput", function(self, button, press, pos)
			table.insert(call_stack, {name = name, type = "local", press = press})
		end)

		pnl:AddLocalListener("OnGlobalMouseInput", function(self, button, press, pos)
			table.insert(call_stack, {name = name, type = "global", press = press})
		-- return nil so others get it too, unless we want to test blocking
		end)

		pnl:AddLocalListener("OnGlobalMouseMove", function(self, pos)
			table.insert(call_stack, {name = name, type = "move"})
		end)

		return pnl
	end

	-- p1 is created first (bottom)
	local p1 = create_panel("p1")
	-- p2 is created second (top)
	local p2 = create_panel("p2")
	-- Mock window for mouse position
	local old_get_mouse_pos = window.GetMousePosition
	window.GetMousePosition = function()
		return Vec2(50, 50)
	end
	local old_get_size = window.GetSize
	window.GetSize = function()
		return Vec2(1000, 1000)
	end
	-- Test 1: Global event order (should be p2 then p1)
	call_stack = {}
	event.Call("MouseInput", "button_1", true)
	local global_calls = {}

	for _, call in ipairs(call_stack) do
		if call.type == "global" then
			table.insert(global_calls, call.name)
		end
	end

	T(global_calls[1])["=="]("p2")
	T(global_calls[2])["=="]("p1")
	-- Test 2: Local event target (should be p2)
	local local_calls = {}

	for _, call in ipairs(call_stack) do
		if call.type == "local" then
			table.insert(local_calls, call.name)
		end
	end

	T(local_calls[1])["=="]("p2")

	-- Test 3: Blocking global event
	p2:AddLocalListener("OnGlobalMouseInput", function()
		return true
	end, "blocker")

	call_stack = {}
	event.Call("MouseInput", "button_1", true)
	global_calls = {}

	for _, call in ipairs(call_stack) do
		if call.type == "global" then
			table.insert(global_calls, call.name)
		end
	end

	T(#global_calls)["=="](1)
	T(global_calls[1])["=="]("p2")
	-- Test 4: Bring to front
	p1:BringToFront() -- p1 is now on top
	call_stack = {}
	event.Call("MouseInput", "button_1", true)
	global_calls = {}

	for _, call in ipairs(call_stack) do
		if call.type == "global" then
			table.insert(global_calls, call.name)
		end
	end

	-- note: p2 still has the "blocker" but p1 is now checked first
	T(global_calls[1])["=="]("p1")
	T(global_calls[2])["=="]("p2")
	T(#global_calls)["=="](2)
	-- Test 5: Global mouse move order
	call_stack = {}
	require("event").Call("Update") -- ecs_gui_system listens to Update for mouse move
	local move_calls = {}

	for _, call in ipairs(call_stack) do
		if call.type == "move" then
			table.insert(move_calls, call.name)
		end
	end

	-- p1 is on top from Test 4
	T(move_calls[1])["=="]("p1")
	T(move_calls[2])["=="]("p2")
	-- Clean up
	window.GetMousePosition = old_get_mouse_pos
	window.GetSize = old_get_size
	Panel.World = old_world
end)
