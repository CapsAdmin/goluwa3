local T = import("test/environment.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local system = import("goluwa/system.lua")
local Window = import("addons/gui/lua/ui/widgets/window.lua")

T.Test2D("request mouse follows panel visibility and removal", function()
	local old_world = Panel.World
	local test_world = Panel.New{
		ComponentSet = {"transform", "gui_element"},
	}
	test_world:SetName("TestWorld")
	test_world.transform:SetSize(Vec2(1000, 1000))
	Panel.World = test_world
	local window = system.GetWindow()
	local old_mouse_trapped = window:GetMouseTrapped()
	local panel = Panel.New{
		mouse_input = {
			RequestMouse = true,
		},
	}

	local function cleanup()
		if panel and panel.IsValid and panel:IsValid() then panel:Remove() end

		if test_world and test_world.IsValid and test_world:IsValid() then
			test_world:Remove()
		end

		Panel.World = old_world
		window:SetMouseTrapped(old_mouse_trapped)

		if window.mouse_trap_requests then
			window.mouse_trap_requests = nil
			window.mouse_trap_request_lookup = nil
		end
	end

	local ok, err = xpcall(
		function()
			window:SetMouseTrapped(true)
			panel:SetParent(test_world)
			T(window:GetMouseTrapped())["=="](false)
			panel.gui_element:SetVisible(false)
			T(window:GetMouseTrapped())["=="](true)
			panel.gui_element:SetVisible(true)
			T(window:GetMouseTrapped())["=="](false)
			window:PushMouseTrapRequest("temporary", true)
			T(window:GetMouseTrapped())["=="](true)
			window:PopMouseTrapRequest("temporary")
			T(window:GetMouseTrapped())["=="](false)
			panel:Remove()
			T(window:GetMouseTrapped())["=="](true)
		end,
		debug.traceback
	)
	cleanup()

	if not ok then error(err, 0) end
end)

T.Test2D("window request mouse restores trapped state when removed", function()
	local old_world = Panel.World
	local test_world = Panel.New{
		ComponentSet = {"transform", "gui_element"},
	}
	test_world:SetName("TestWorld")
	test_world.transform:SetSize(Vec2(1000, 1000))
	Panel.World = test_world
	local window = system.GetWindow()
	local old_mouse_trapped = window:GetMouseTrapped()
	local editor = Window{
		RequestMouse = true,
	}

	local function cleanup()
		if editor and editor.IsValid and editor:IsValid() then editor:Remove() end

		if test_world and test_world.IsValid and test_world:IsValid() then
			test_world:Remove()
		end

		Panel.World = old_world
		window:SetMouseTrapped(old_mouse_trapped)

		if window.mouse_trap_requests then
			window.mouse_trap_requests = nil
			window.mouse_trap_request_lookup = nil
		end
	end

	local ok, err = xpcall(
		function()
			window:SetMouseTrapped(true)
			editor:SetParent(test_world)
			T(window:GetMouseTrapped())["=="](false)
			editor:Remove()
			T(window:GetMouseTrapped())["=="](true)
		end,
		debug.traceback
	)
	cleanup()

	if not ok then error(err, 0) end
end)
