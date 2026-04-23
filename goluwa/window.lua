local prototype = import("goluwa/prototype.lua")
local Window = prototype.CreateTemplate("window")
import.loaded["goluwa/window.lua"] = Window
local system = import("goluwa/system.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local event = import("goluwa/event.lua")
local window = library()
local input = import("goluwa/input.lua")
local timer = import("goluwa/timer.lua")
Window:GetSet("Title", "no title")
Window:GetSet("Size", Vec2())
Window:GetSet("MouseDelta", Vec2())
Window:GetSet("MouseTrapped", false)
Window:GetSet("Cursor", "arrow")
Window:IsSet("Focused", false)
Window.Cursors = {
	hand = true,
	arrow = true,
	trapped = true,
	hidden = true,
	crosshair = true,
	text_input = true,
	vertical_resize = true,
	horizontal_resize = true,
	horizontal_resize = true,
	vertical_resize = true,
	top_right_resize = true,
	bottom_left_resize = true,
	top_left_resize = true,
	bottom_right_resize = true,
	all_resize = true,
}
Window.Keys = {}
Window.Buttons = {}

function Window:SetMouseTrapped(b)
	if b then self:CaptureMouse() else self:ReleaseMouse() end
end

function Window:GetMouseTrapped()
	return self:IsMouseCaptured()
end

local function nyi()
	local func = debug.getinfo(2).func

	for k, v in pairs(Window) do
		if v == func then
			local msg = "function Window:" .. k .. "() is not implemented"
			error(msg, 3)
		end
	end
end

function Window:Initialize()
	nyi()
end

function Window:OnRemove()
	system.UnregisterWindow(self)
end

Window.OnRemoved = Window.OnRemove

function Window:Maximize()
	nyi()
end

function Window:Minimize()
	nyi()
end

function Window:Restore()
	nyi()
end

function Window:GetPosition()
	nyi()
end

function Window:GetFramebufferSize()
	nyi()
end

function Window:GetMousePosition()
	nyi()
end

function Window:SetMousePosition(pos)
	nyi()
end

function Window:ShouldWarpMouseWhenCaptured()
	return true
end

function Window:OnUpdate(dt) end

function Window:OnMinimize()
	return event.Call("WindowMinimize", self)
end

function Window:OnMaximize()
	return event.Call("WindowMaximize", self)
end

function Window:OnGainedFocus()
	return event.Call("WindowGainedFocus", self)
end

function Window:OnLostFocus()
	local b = event.Call("WindowLostFocus", self)

	if b ~= nil then return b end

	input.ReleaseAll("Mouse", function(key, press)
		event.Call("MouseInput", key, press)
	end)

	input.ReleaseAll("Key", function(key, press)
		event.Call("KeyInput", key, press)
	end)

	return b
end

function Window:OnPositionChanged(pos)
	return event.Call("WindowPositionChanged", self, pos)
end

function Window:OnSizeChanged(size)
	return event.Call("WindowSizeChanged", self, size)
end

function Window:OnFramebufferResized(size)
	return event.Call("WindowFramebufferResized", self, size)
end

function Window:OnCursorEnter()
	return event.Call("WindowCursorEnter", self)
end

function Window:OnCursorLeave()
	return event.Call("WindowCursorLeave", self)
end

function Window:OnClose()
	system.ShutDown()
	return event.Call("WindowClose", self)
end

function Window:OnCursorPosition(pos)
	return event.Call("WindowCursorPosition", self, pos)
end

function Window:OnDrop(paths)
	return event.Call("WindowDrop", self, paths)
end

function Window:OnCharInput(str)
	local b = event.Call("WindowCharInput", self, str)

	if b ~= nil then return b end

	return event.Call("CharInput", str)
end

function Window:OnKeyInput(key, press)
	self.key_state = self.key_state or {}

	if self.key_state[key] == press then return end

	self.key_state[key] = press
	local b = event.Call("WindowKeyInput", self, key, press)

	if b ~= nil then return b end

	if self.key_trigger then self.key_trigger(key, press) end

	return event.Call("KeyInput", key, press)
end

function Window:OnKeyInputRepeat(key, press)
	local b = event.Call("WindowKeyInputRepeat", self, key, press)

	if b ~= nil then return b end

	b = event.Call("KeyInputRepeat", key, press)

	if b ~= nil then return b end

	return self:OnKeyInput(key, press)
end

function Window:OnMouseInput(key, press)
	local b = event.Call("WindowMouseInput", self, key, press)

	if b ~= nil then return b end

	if self.mouse_trigger then self.mouse_trigger(key, press) end

	return event.Call("MouseInput", key, press)
end

function Window:OnMouseScroll(dir)
	local b = event.Call("WindowMouseScroll", self, dir)

	if b ~= nil then return b end

	local x, y = dir:Unpack()

	if y ~= 0 then
		for _ = 1, math.abs(y) do
			if y > 0 then
				self:OnMouseInput("mwheel_up", true)
			else
				self:OnMouseInput("mwheel_down", true)
			end
		end

		timer.Delay(function()
			if y > 0 then
				self:OnMouseInput("mwheel_up", false)
			else
				self:OnMouseInput("mwheel_down", false)
			end
		end)
	end

	if x ~= 0 then
		for _ = 1, math.abs(x) do
			if x > 0 then
				self:OnMouseInput("mwheel_left", true)
			else
				self:OnMouseInput("mwheel_right", true)
			end
		end

		timer.Delay(function()
			if x > 0 then
				self:OnMouseInput("mwheel_left", false)
			else
				self:OnMouseInput("mwheel_right", false)
			end
		end)
	end

	return event.Call("MouseScroll", dir)
end

if jit.os == "OSX" then
	import("goluwa/window_implementations/macos.lua")(Window)
elseif jit.os == "Windows" then
	import("goluwa/window_implementations/windows.lua")(Window)
elseif jit.os == "Linux" then
	import("goluwa/window_implementations/linux_wayland.lua")(Window)
end

function Window.New(width, height, title, flags)
	local self = Window:CreateObject()

	if title ~= nil then self.Title = title end

	if width ~= nil and height ~= nil then self.Size = Vec2(width, height) end

	self:Initialize()
	system.RegisterWindow(self)
	self.key_trigger = input.SetupInputEvent("Key")
	self.mouse_trigger = input.SetupInputEvent("Mouse")
	event.Call("WindowOpened", self)
	self:AddGlobalEvent("Update") -- calls :OnUpdate
	return self
end

return Window:Register()
