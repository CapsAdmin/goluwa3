local T = import("test/environment.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local objects = import("goluwa/objects/objects.lua")

T.Test("mouse input event order (local and global)", function()
	local old_world = Panel.World
	Panel.World = Panel.New{
		ComponentSet = {"transform", "visual"},
	}
	Panel.World:SetName("TestWorld")
	Panel.World.transform:SetSize(Vec2(1000, 1000))
	local call_stack = {}

	local function create_panel(name, pos, size)
		local pnl = Panel.New{
			Parent = Panel.World,
			Name = name,
			transform = true,
			visual = true,
			mouse_input = true,
		}
		pnl.transform:SetPosition(pos or Vec2(0, 0))
		pnl.transform:SetSize(size or Vec2(100, 100))

		pnl:AddLocalListener("OnMouseInput", function(self, button, press, pos)
			table.insert(call_stack, {name = name, type = "local", press = press})
		end)

		pnl:AddLocalListener("OnGlobalMouseInput", function(self, button, press, pos)
			table.insert(call_stack, {name = name, type = "global", press = press})
		end)

		pnl:AddLocalListener("OnGlobalMouseMove", function(self, pos)
			table.insert(call_stack, {name = name, type = "move"})
		end)

		return pnl
	end

	local p1 = create_panel("p1")
	local p2 = create_panel("p2")
	local window = system.GetWindow()
	local old_get_mouse_pos = window.GetMousePosition
	window.GetMousePosition = function()
		return Vec2(50, 50)
	end
	local old_get_size = window.GetSize
	window.GetSize = function()
		return Vec2(1000, 1000)
	end
	call_stack = {}
	event.Call("MouseInput", "button_1", true)
	local global_calls = {}

	for _, call in ipairs(call_stack) do
		if call.type == "global" then table.insert(global_calls, call.name) end
	end

	T(global_calls[1])["=="]("p2")
	T(global_calls[2])["=="]("p1")
	local local_calls = {}

	for _, call in ipairs(call_stack) do
		if call.type == "local" then table.insert(local_calls, call.name) end
	end

	T(local_calls[1])["=="]("p2")

	p2:AddLocalListener("OnGlobalMouseInput", function()
		return true
	end, "blocker")

	call_stack = {}
	event.Call("MouseInput", "button_1", true)
	global_calls = {}

	for _, call in ipairs(call_stack) do
		if call.type == "global" then table.insert(global_calls, call.name) end
	end

	T(#global_calls)["=="](1)
	T(global_calls[1])["=="]("p2")
	p1:BringToFront()
	call_stack = {}
	event.Call("MouseInput", "button_1", true)
	global_calls = {}

	for _, call in ipairs(call_stack) do
		if call.type == "global" then table.insert(global_calls, call.name) end
	end

	T(global_calls[1])["=="]("p1")
	T(global_calls[2])["=="]("p2")
	T(#global_calls)["=="](2)
	call_stack = {}
	import("goluwa/event.lua").Call("Update")
	local move_calls = {}

	for _, call in ipairs(call_stack) do
		if call.type == "move" then table.insert(move_calls, call.name) end
	end

	T(move_calls[1])["=="]("p1")
	T(move_calls[2])["=="]("p2")
	window.GetMousePosition = old_get_mouse_pos
	window.GetSize = old_get_size
	Panel.World = old_world
end)
