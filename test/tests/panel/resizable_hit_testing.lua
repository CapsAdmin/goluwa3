local T = import("test/environment.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")

T.Test("panel resize respects topmost hovered panel", function()
	local old_world = Panel.World
	Panel.World = Panel.New{
		ComponentSet = {"transform", "gui_element"},
	}
	Panel.World:SetName("TestWorld")
	Panel.World.transform:SetSize(Vec2(1000, 1000))
	local back = Panel.New{
		Parent = Panel.World,
		Name = "back",
		transform = true,
		gui_element = true,
		mouse_input = true,
		resizable = true,
	}
	back.transform:SetPosition(Vec2(0, 0))
	back.transform:SetSize(Vec2(100, 100))
	local front = Panel.New{
		Parent = Panel.World,
		Name = "front",
		transform = true,
		gui_element = true,
		mouse_input = true,
		resizable = true,
	}
	front.transform:SetPosition(Vec2(20, 20))
	front.transform:SetSize(Vec2(100, 100))
	local window = system.GetWindow()
	local old_get_mouse_pos = window.GetMousePosition
	window.GetMousePosition = function()
		return Vec2(98, 50)
	end
	event.Call("MouseInput", "button_1", true)
	T(back.resizable:IsResizing())["=="](false)
	T(front.resizable:IsResizing())["=="](false)
	event.Call("MouseInput", "button_1", false)
	window.GetMousePosition = old_get_mouse_pos
	Panel.World = old_world
end)

T.Test("panel resize works on extended border of topmost panel", function()
	local old_world = Panel.World
	Panel.World = Panel.New{
		ComponentSet = {"transform", "gui_element"},
	}
	Panel.World:SetName("TestWorld")
	Panel.World.transform:SetSize(Vec2(1000, 1000))
	local back = Panel.New{
		Parent = Panel.World,
		Name = "back",
		transform = true,
		gui_element = true,
		mouse_input = true,
		resizable = true,
	}
	back.transform:SetPosition(Vec2(0, 0))
	back.transform:SetSize(Vec2(100, 100))
	local front = Panel.New{
		Parent = Panel.World,
		Name = "front",
		transform = true,
		gui_element = true,
		mouse_input = true,
		resizable = true,
	}
	front.transform:SetPosition(Vec2(20, 20))
	front.transform:SetSize(Vec2(100, 100))
	local window = system.GetWindow()
	local old_get_mouse_pos = window.GetMousePosition
	window.GetMousePosition = function()
		return Vec2(13, 50)
	end
	event.Call("MouseInput", "button_1", true)
	T(front.resizable:IsResizing())["=="](true)
	T(back.resizable:IsResizing())["=="](false)
	event.Call("MouseInput", "button_1", false)
	window.GetMousePosition = old_get_mouse_pos
	Panel.World = old_world
end)

T.Test("panel resize works on inside edge over child panel", function()
	local old_world = Panel.World
	Panel.World = Panel.New{
		ComponentSet = {"transform", "gui_element"},
	}
	Panel.World:SetName("TestWorld")
	Panel.World.transform:SetSize(Vec2(1000, 1000))
	local window_panel = Panel.New{
		Parent = Panel.World,
		Name = "window",
		transform = true,
		gui_element = true,
		mouse_input = true,
		resizable = true,
	}
	window_panel.transform:SetPosition(Vec2(20, 20))
	window_panel.transform:SetSize(Vec2(100, 100))
	local child = Panel.New{
		Parent = window_panel,
		Name = "child",
		transform = true,
		gui_element = true,
		mouse_input = true,
	}
	child.transform:SetPosition(Vec2(0, 0))
	child.transform:SetSize(Vec2(100, 100))
	local window = system.GetWindow()
	local old_get_mouse_pos = window.GetMousePosition
	window.GetMousePosition = function()
		return Vec2(25, 50)
	end
	event.Call("MouseInput", "button_1", true)
	T(window_panel.resizable:IsResizing())["=="](true)
	event.Call("MouseInput", "button_1", false)
	window.GetMousePosition = old_get_mouse_pos
	Panel.World = old_world
end)

T.Test("panel resize is not blocked by child global false return", function()
	local old_world = Panel.World
	Panel.World = Panel.New{
		ComponentSet = {"transform", "gui_element"},
	}
	Panel.World:SetName("TestWorld")
	Panel.World.transform:SetSize(Vec2(1000, 1000))
	local window_panel = Panel.New{
		Parent = Panel.World,
		Name = "window",
		transform = true,
		gui_element = true,
		mouse_input = true,
		resizable = true,
	}
	window_panel.transform:SetPosition(Vec2(20, 20))
	window_panel.transform:SetSize(Vec2(100, 100))
	local child = Panel.New{
		Parent = window_panel,
		Name = "child",
		transform = true,
		gui_element = true,
		mouse_input = true,
	}
	child.transform:SetPosition(Vec2(0, 0))
	child.transform:SetSize(Vec2(100, 100))

	child:AddLocalListener("OnGlobalMouseInput", function()
		return false
	end, "test_false_blocker")

	local window = system.GetWindow()
	local old_get_mouse_pos = window.GetMousePosition
	window.GetMousePosition = function()
		return Vec2(25, 50)
	end
	event.Call("MouseInput", "button_1", true)
	T(window_panel.resizable:IsResizing())["=="](true)
	event.Call("MouseInput", "button_1", false)
	window.GetMousePosition = old_get_mouse_pos
	Panel.World = old_world
end)

T.Test("panel resize cursor stays locked during drag over child move handler", function()
	local old_world = Panel.World
	Panel.World = Panel.New{
		ComponentSet = {"transform", "gui_element"},
	}
	Panel.World:SetName("TestWorld")
	Panel.World.transform:SetSize(Vec2(1000, 1000))
	local window_panel = Panel.New{
		Parent = Panel.World,
		Name = "window",
		transform = true,
		gui_element = true,
		mouse_input = true,
		resizable = true,
	}
	window_panel.transform:SetPosition(Vec2(20, 20))
	window_panel.transform:SetSize(Vec2(100, 100))
	local child = Panel.New{
		Parent = window_panel,
		Name = "child",
		transform = true,
		gui_element = true,
		mouse_input = true,
	}
	child.transform:SetPosition(Vec2(0, 0))
	child.transform:SetSize(Vec2(100, 100))
	child.mouse_input:SetCursor("hand")

	child:AddLocalListener(
		"OnGlobalMouseMove",
		function(self, pos)
			self.mouse_input:SetCursor("hand")
			return true
		end,
		"test_move_cursor_handler"
	)

	local window = system.GetWindow()
	local old_get_mouse_pos = window.GetMousePosition
	local old_get_mouse_delta = window.GetMouseDelta
	window.GetMousePosition = function()
		return Vec2(25, 50)
	end
	window.GetMouseDelta = function()
		return Vec2(1, 0)
	end
	event.Call("MouseInput", "button_1", true)
	event.Call("Update")
	T(window_panel.resizable:IsResizing())["=="](true)
	T(window:GetCursor())["=="]("horizontal_resize")
	event.Call("MouseInput", "button_1", false)
	window.GetMousePosition = old_get_mouse_pos
	window.GetMouseDelta = old_get_mouse_delta
	Panel.World = old_world
end)

T.Test("panel resize cursor updates immediately from child hover cursor", function()
	local old_world = Panel.World
	Panel.World = Panel.New{
		ComponentSet = {"transform", "gui_element"},
	}
	Panel.World:SetName("TestWorld")
	Panel.World.transform:SetSize(Vec2(1000, 1000))
	local window_panel = Panel.New{
		Parent = Panel.World,
		Name = "window",
		transform = true,
		gui_element = true,
		mouse_input = true,
		resizable = true,
	}
	window_panel.transform:SetPosition(Vec2(20, 20))
	window_panel.transform:SetSize(Vec2(100, 100))
	local child = Panel.New{
		Parent = window_panel,
		Name = "child",
		transform = true,
		gui_element = true,
		mouse_input = true,
	}
	child.transform:SetPosition(Vec2(0, 0))
	child.transform:SetSize(Vec2(100, 100))
	child.mouse_input:SetCursor("hand")
	local window = system.GetWindow()
	local old_get_mouse_pos = window.GetMousePosition
	local old_cursor = window:GetCursor()
	window:SetCursor("hand")
	window.GetMousePosition = function()
		return Vec2(25, 50)
	end
	event.Call("MouseInput", "button_1", true)
	T(window_panel.resizable:IsResizing())["=="](true)
	T(window:GetCursor())["=="]("horizontal_resize")
	event.Call("MouseInput", "button_1", false)
	window.GetMousePosition = old_get_mouse_pos
	window:SetCursor(old_cursor)
	Panel.World = old_world
end)
