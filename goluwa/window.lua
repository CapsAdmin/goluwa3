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
Window:GetSet("Position", Vec2())
Window:GetSet("Size", Vec2())
Window:GetSet("MousePosition", Vec2())
Window:GetSet("MouseDelta", Vec2())
Window:GetSet("MouseTrapped", false)
Window:GetSet("Clipboard")
Window:GetSet("Flags")
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

function Window:PreWindowSetup()
	nyi()
end

function Window:PostWindowSetup()
	nyi()
end

function Window:OnRemove()
	system.UnregisterWindow(self)
end

function Window:Maximize()
	nyi()
end

function Window:Minimize()
	nyi()
end

function Window:Restore()
	nyi()
end

function Window:GetFramebufferSize()
	nyi()
end

function Window:OnUpdate(dt) end

function Window:OnMinimize() end

function Window:OnMaximize() end

function Window:OnGainedFocus() end

function Window:OnLostFocus() end

function Window:OnPositionChanged(pos) end

function Window:OnSizeChanged(size) end

function Window:OnFramebufferResized(size) end

function Window:OnCursorEnter() end

function Window:OnCursorLeave() end

function Window:OnClose() end

function Window:SwapInterval() end

function Window:OnCursorPosition(x, y) end

function Window:OnDrop(paths) end

function Window:OnCharInput(str) end

function Window:OnKeyInput(key, press) end

function Window:OnKeyInputRepeat(key, press) end

function Window:OnMouseInput(key, press) end

function Window:OnMouseScroll(x, y) end

function Window:UpdateMousePosition(pos)
	if self:OnCursorPosition(self, pos) ~= false then
		event.Call("WindowCursorPosition", self, pos)
	end
end

function Window:CallEvent(name, ...)
	local b = self["On" .. name](self, ...)

	if b ~= false then b = event.Call("Window" .. name, self, ...) end

	return b
end

function Window:OnClose()
	self:Remove()
	system.ShutDown()
end

if jit.os == "OSX" then
	import("goluwa/window_implementations/macos.lua")(Window)
elseif jit.os == "Linux" then
	import("goluwa/window_implementations/linux_wayland.lua")(Window)
end

function Window.New(width, height, title, flags)
	local self = Window:CreateObject()
	self:Initialize()
	self:SetTitle(title)

	if width and height then self:SetSize(Vec2(width, height)) end

	self:SetFlags(flags)
	system.RegisterWindow(self)

	local key_trigger = input.SetupInputEvent("Key")
	local mouse_trigger = input.SetupInputEvent("Mouse")
	local event_id = "window_events_" .. tostring(self)
	local release_inputs_id = "window_release_inputs_" .. tostring(self)

	local function ADD_EVENT(name, callback)
		local nice = name:sub(7)

		event.AddListener(name, event_id .. "_" .. name, function(_wnd, ...)
			if _wnd ~= self then return end

			if not callback or callback(...) ~= false then
				return event.Call(nice, ...)
			end
		end)
	end

	ADD_EVENT("WindowCharInput")
	ADD_EVENT("WindowKeyInput", key_trigger)
	ADD_EVENT("WindowMouseInput", mouse_trigger)
	ADD_EVENT("WindowKeyInputRepeat")
	local mouse_trigger = function(key, press)
		mouse_trigger(key, press)
		event.Call("MouseInput", key, press)
	end

	event.AddListener("WindowLostFocus", release_inputs_id, function(focused_wnd)
		if focused_wnd ~= self then return end

		input.ReleaseAll("Mouse", function(key, press)
			event.Call("MouseInput", key, press)
		end)

		input.ReleaseAll("Key", function(key, press)
			event.Call("KeyInput", key, press)
		end)
	end)

	ADD_EVENT("WindowMouseScroll", function(dir)
		local x, y = dir:Unpack()

		if y ~= 0 then
			for _ = 1, math.abs(y) do
				if y > 0 then
					mouse_trigger("mwheel_up", true)
				else
					mouse_trigger("mwheel_down", true)
				end
			end

			timer.Delay(function()
				if y > 0 then
					mouse_trigger("mwheel_up", false)
				else
					mouse_trigger("mwheel_down", false)
				end
			end)
		end

		if x ~= 0 then
			for _ = 1, math.abs(x) do
				if x > 0 then
					mouse_trigger("mwheel_left", true)
				else
					mouse_trigger("mwheel_right", true)
				end
			end

			timer.Delay(function()
				if x > 0 then
					mouse_trigger("mwheel_left", false)
				else
					mouse_trigger("mwheel_right", false)
				end
			end)
		end
	end)

	event.Call("WindowOpened", self)

	return self
end

return Window:Register()