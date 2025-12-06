local ffi = require("ffi")
local objc = require("bindings.objc")
local cocoa = {}
-- Load required frameworks
objc.loadFramework("Cocoa")
objc.loadFramework("QuartzCore")
-- Create a custom window delegate class to handle close events
local WindowDelegate = nil
local close_flags = {} -- Store close state per window
local function setup_window_delegate()
	if WindowDelegate then return WindowDelegate end

	-- Create delegate class
	WindowDelegate = objc.newClass("LuaWindowDelegate", "NSObject")

	-- Add windowShouldClose: method
	objc.addMethod(
		WindowDelegate,
		"windowShouldClose:",
		"c@:@",
		function(self, sel, sender)
			-- Mark this window as should close
			local window_ptr = tostring(sender)
			close_flags[window_ptr] = true
			return 1 -- YES, allow close
		end
	)

	return WindowDelegate
end

local function CGRectMake(x, y, width, height)
	return ffi.new("CGRect", {{x, y}, {width, height}})
end

-- Initialize Cocoa application and create window
local function init_cocoa()
	local pool = objc.Class("NSAutoreleasePool"):Call("alloc"):Call("init")
	local app = objc.Class("NSApplication"):Call("sharedApplication")
	app:Call("setActivationPolicy:", 0)
	app:Call("activateIgnoringOtherApps:", true)
	local frame = CGRectMake(100, 100, 800, 600)
	local styleMask = bit.bor(1, 2, 4, 8)
	local window = objc.Class("NSWindow"):Call("alloc"):Call("initWithContentRect:styleMask:backing:defer:", frame, styleMask, 2, false)
	window:Call("makeKeyAndOrderFront:", ffi.cast("id", 0))
	local contentView = window:GetProperty("contentView")
	local metal_layer = objc.Class("CAMetalLayer"):Call("layer")
	local bounds = contentView:GetProperty("bounds")
	metal_layer:Call("setDrawableSize:", bounds.size)
	contentView:Call("setWantsLayer:", true)
	contentView:Call("setLayer:", metal_layer)
	return window, metal_layer
end

-- NSEvent type constants
local NSEventType = {
	LeftMouseDown = 1,
	LeftMouseUp = 2,
	RightMouseDown = 3,
	RightMouseUp = 4,
	MouseMoved = 5,
	LeftMouseDragged = 6,
	RightMouseDragged = 7,
	MouseEntered = 8,
	MouseExited = 9,
	KeyDown = 10,
	KeyUp = 11,
	FlagsChanged = 12,
	AppKitDefined = 13,
	SystemDefined = 14,
	ApplicationDefined = 15,
	Periodic = 16,
	CursorUpdate = 17,
	ScrollWheel = 22,
	TabletPoint = 23,
	TabletProximity = 24,
	OtherMouseDown = 25,
	OtherMouseUp = 26,
	OtherMouseDragged = 27,
}
-- NSAppKitDefined subtypes
local NSEventSubtype = {
	WindowExposed = 0,
	ApplicationActivated = 1,
	ApplicationDeactivated = 2,
	WindowMoved = 4,
	ScreenChanged = 8,
}
-- NSEvent modifier flags
local NSEventModifierFlags = {
	Shift = 0x20000,
	Control = 0x40000,
	Option = 0x80000,
	Command = 0x100000,
	-- Device-specific modifier flags (for determining left vs right)
	DeviceIndependentFlagsMask = 0xFFFF0000,
}
-- Device-specific modifier key codes (lower bits that distinguish left/right)
local NSEventModifierDeviceFlags = {
	LeftShift = 0x0002,
	RightShift = 0x0004,
	LeftControl = 0x0001,
	RightControl = 0x2000,
	LeftAlt = 0x0020,
	RightAlt = 0x0040,
	LeftCommand = 0x0008,
	RightCommand = 0x0010,
}
-- Key code mapping (US keyboard layout)
local keycodes = {
	[0x00] = "a",
	[0x01] = "s",
	[0x02] = "d",
	[0x03] = "f",
	[0x04] = "h",
	[0x05] = "g",
	[0x06] = "z",
	[0x07] = "x",
	[0x08] = "c",
	[0x09] = "v",
	[0x0B] = "b",
	[0x0C] = "q",
	[0x0D] = "w",
	[0x0E] = "e",
	[0x0F] = "r",
	[0x10] = "y",
	[0x11] = "t",
	[0x12] = "1",
	[0x13] = "2",
	[0x14] = "3",
	[0x15] = "4",
	[0x16] = "6",
	[0x17] = "5",
	[0x18] = "=",
	[0x19] = "9",
	[0x1A] = "7",
	[0x1B] = "-",
	[0x1C] = "8",
	[0x1D] = "0",
	[0x1E] = "]",
	[0x1F] = "o",
	[0x20] = "u",
	[0x21] = "[",
	[0x22] = "i",
	[0x23] = "p",
	[0x24] = "return",
	[0x25] = "l",
	[0x26] = "j",
	[0x27] = "'",
	[0x28] = "k",
	[0x29] = ";",
	[0x2A] = "\\",
	[0x2B] = ",",
	[0x2C] = "/",
	[0x2D] = "n",
	[0x2E] = "m",
	[0x2F] = ".",
	[0x30] = "tab",
	[0x31] = "space",
	[0x32] = "`",
	[0x33] = "backspace",
	[0x35] = "escape",
	[0x37] = "left_command",
	[0x38] = "left_shift",
	[0x39] = "capslock",
	[0x3A] = "left_alt",
	[0x3B] = "left_control",
	[0x3C] = "right_shift",
	[0x3D] = "right_alt",
	[0x3E] = "right_control",
	[0x7B] = "left",
	[0x7C] = "right",
	[0x7D] = "down",
	[0x7E] = "up",
	[0x72] = "help",
	[0x73] = "home",
	[0x74] = "pageup",
	[0x75] = "delete",
	[0x77] = "end",
	[0x79] = "pagedown",
	[0x47] = "clear",
	-- Function keys
	[0x7A] = "f1",
	[0x78] = "f2",
	[0x63] = "f3",
	[0x76] = "f4",
	[0x60] = "f5",
	[0x61] = "f6",
	[0x62] = "f7",
	[0x64] = "f8",
	[0x65] = "f9",
	[0x6D] = "f10",
	[0x67] = "f11",
	[0x6F] = "f12",
}
-- Track previous modifier state for FlagsChanged events
local last_modifier_flags = 0

-- Helper to convert NSEvent to our event structure
local function convert_nsevent(nsevent, window)
	if nsevent == nil or nsevent == objc.ptr(nil) then return nil end

	local event_type = tonumber(nsevent:Call("type"))
	local modifier_flags = tonumber(nsevent:Call("modifierFlags"))
	-- Extract modifiers
	local modifiers = {
		shift = bit.band(modifier_flags, NSEventModifierFlags.Shift) ~= 0,
		control = bit.band(modifier_flags, NSEventModifierFlags.Control) ~= 0,
		alt = bit.band(modifier_flags, NSEventModifierFlags.Option) ~= 0,
		command = bit.band(modifier_flags, NSEventModifierFlags.Command) ~= 0,
	}

	-- Keyboard events
	if event_type == NSEventType.KeyDown then
		local keycode = tonumber(nsevent:Call("keyCode"))
		local key = keycodes[keycode] or "unknown"
		local chars = nsevent:Call("characters")
		local char = nil

		if chars ~= nil and chars ~= objc.ptr(nil) then
			local cstr = chars:Call("UTF8String")

			if cstr ~= nil then char = ffi.string(cstr) end
		end

		return {
			type = "key_press",
			key = key,
			char = char,
			modifiers = modifiers,
		}
	elseif event_type == NSEventType.KeyUp then
		local keycode = tonumber(nsevent:Call("keyCode"))
		local key = keycodes[keycode] or "unknown"
		return {
			type = "key_release",
			key = key,
			modifiers = modifiers,
		}
	-- FlagsChanged events (modifier keys)
	elseif event_type == NSEventType.FlagsChanged then
		-- Determine which modifier key changed by comparing with previous state
		local changed = bit.bxor(modifier_flags, last_modifier_flags)
		local pressed = bit.band(modifier_flags, changed) ~= 0
		-- Check each modifier key
		local key = nil

		if bit.band(changed, NSEventModifierDeviceFlags.LeftShift) ~= 0 then
			key = "left_shift"
		elseif bit.band(changed, NSEventModifierDeviceFlags.RightShift) ~= 0 then
			key = "right_shift"
		elseif bit.band(changed, NSEventModifierDeviceFlags.LeftControl) ~= 0 then
			key = "left_control"
		elseif bit.band(changed, NSEventModifierDeviceFlags.RightControl) ~= 0 then
			key = "right_control"
		elseif bit.band(changed, NSEventModifierDeviceFlags.LeftAlt) ~= 0 then
			key = "left_alt"
		elseif bit.band(changed, NSEventModifierDeviceFlags.RightAlt) ~= 0 then
			key = "right_alt"
		elseif bit.band(changed, NSEventModifierDeviceFlags.LeftCommand) ~= 0 then
			key = "left_command"
		elseif bit.band(changed, NSEventModifierDeviceFlags.RightCommand) ~= 0 then
			key = "right_command"
		end

		last_modifier_flags = modifier_flags

		if key then
			return {
				type = pressed and "key_press" or "key_release",
				key = key,
				modifiers = modifiers,
			}
		end

		return nil
	-- Mouse button events
	elseif
		event_type == NSEventType.LeftMouseDown or
		event_type == NSEventType.RightMouseDown or
		event_type == NSEventType.OtherMouseDown
	then
		local location = nsevent:Call("locationInWindow")
		local button = event_type == NSEventType.LeftMouseDown and
			"left" or
			event_type == NSEventType.RightMouseDown and
			"right" or
			"middle"
		return {
			type = "mouse_button",
			action = "pressed",
			button = button,
			x = tonumber(location.x),
			y = tonumber(location.y),
			modifiers = modifiers,
		}
	elseif
		event_type == NSEventType.LeftMouseUp or
		event_type == NSEventType.RightMouseUp or
		event_type == NSEventType.OtherMouseUp
	then
		local location = nsevent:Call("locationInWindow")
		local button = event_type == NSEventType.LeftMouseUp and
			"left" or
			event_type == NSEventType.RightMouseUp and
			"right" or
			"middle"
		return {
			type = "mouse_button",
			action = "released",
			button = button,
			x = tonumber(location.x),
			y = tonumber(location.y),
			modifiers = modifiers,
		}
	-- Mouse movement
	elseif
		event_type == NSEventType.MouseMoved or
		event_type == NSEventType.LeftMouseDragged or
		event_type == NSEventType.RightMouseDragged or
		event_type == NSEventType.OtherMouseDragged
	then
		local location = nsevent:Call("locationInWindow")
		local delta_x = tonumber(nsevent:Call("deltaX"))
		local delta_y = tonumber(nsevent:Call("deltaY"))
		return {
			type = "mouse_move",
			x = tonumber(location.x),
			y = tonumber(location.y),
			delta_x = delta_x,
			delta_y = delta_y,
			modifiers = modifiers,
		}
	-- Scroll wheel
	elseif event_type == NSEventType.ScrollWheel then
		local location = nsevent:Call("locationInWindow")
		local delta_x = tonumber(nsevent:Call("scrollingDeltaX"))
		local delta_y = tonumber(nsevent:Call("scrollingDeltaY"))
		return {
			type = "mouse_scroll",
			x = tonumber(location.x),
			y = tonumber(location.y),
			delta_x = delta_x,
			delta_y = delta_y,
			modifiers = modifiers,
		}
	end

	return nil
end

local NSEventMaskAny = 0xFFFFFFFFFFFFFFFFULL
local dequeue = true

-- Event loop helpers
local function poll_events(app, window, event_list)
	local distantPast = objc.Class("NSDate"):Call("distantPast")
	local mode = objc.Class("NSString"):Call("stringWithUTF8String:", "kCFRunLoopDefaultMode")
	local event = app:Call(
		"nextEventMatchingMask:untilDate:inMode:dequeue:",
		NSEventMaskAny,
		distantPast,
		mode,
		dequeue
	)

	if event ~= nil and event ~= objc.ptr(nil) then
		local event_type = tonumber(event:Call("type"))
		local converted = convert_nsevent(event, window)

		if converted then table.insert(event_list, converted) end

		if
			event_type ~= NSEventType.KeyDown and
			event_type ~= NSEventType.KeyUp and
			event_type ~= NSEventType.FlagsChanged
		then
			app:Call("sendEvent:", event)
		end

		app:Call("updateWindows")
		return true
	end

	return false
end

-- Helper to get the NSApplication singleton
local function get_app()
	return objc.Class("NSApplication"):Call("sharedApplication")
end

-- CGDisplayHideCursor / CGDisplayShowCursor
ffi.cdef[[
	int CGDisplayHideCursor(uint32_t display);
	int CGDisplayShowCursor(uint32_t display);
	int CGAssociateMouseAndMouseCursorPosition(bool connected);
	typedef struct { double x; double y; } CGPoint;
	void CGWarpMouseCursorPosition(CGPoint newCursorPosition);
]]
local CG = ffi.load("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
local meta = {}
meta.__index = meta

function cocoa.window()
	local self = setmetatable({}, meta)
	self.window, self.metal_layer = init_cocoa()
	self.last_width = nil
	self.last_height = nil
	self.cursor_hidden = false
	self.mouse_captured = false
	self.last_mouse_x = nil
	self.last_mouse_y = nil
	return self
end

function meta:Initialize()
	self.app = get_app()
	self.app:Call("finishLaunching")
	setup_window_delegate()
	local delegate = WindowDelegate:Call("alloc"):Call("init")
	self.window:Call("setDelegate:", delegate)
	self.window_ptr = tostring(self.window)
	close_flags[self.window_ptr] = false
end

function meta:SetTitle(str)
	self.window:Call("setTitle:", objc.Class("NSString"):Call("stringWithUTF8String:", str))
end

function meta:OpenWindow()
	self.window:Call("makeKeyAndOrderFront:", ffi.cast("id", 0))
	self.app:Call("activateIgnoringOtherApps:", true)
end

function meta:GetSurfaceHandle()
	return self.metal_layer
end

function meta:IsVisible()
	local isVisible = self.window:Call("isVisible")
	return not isVisible or isVisible == 0
end

function meta:GetSize()
	local window_frame = self.window:Call("frame")
	return tonumber(window_frame.size.width), tonumber(window_frame.size.height)
end

function meta:ReadEvents()
	local events = {}

	while poll_events(self.app, self.window, events) do

	end

	-- Check if window close was requested (via close button or delegate)
	if close_flags[self.window_ptr] then
		table.insert(events, {
			type = "window_close",
		})
	-- Don't reset the flag - close should be persistent
	end

	-- Poll for window size changes
	local current_width, current_height = self:GetSize()

	-- Initialize on first call
	if self.last_width == nil then
		self.last_width = current_width
		self.last_height = current_height
	elseif current_width ~= self.last_width or current_height ~= self.last_height then
		table.insert(
			events,
			{
				type = "window_resize",
				width = current_width,
				height = current_height,
			}
		)
		self.last_width = current_width
		self.last_height = current_height
		local content_view = self.window:GetProperty("contentView")
		local bounds = content_view:GetProperty("bounds")
		self.metal_layer:Call("setDrawableSize:", bounds.size)
	end

	return events
end

function meta:GetWindowSize()
	local window_frame = self.window:Call("frame")
	return tonumber(window_frame.size.width), tonumber(window_frame.size.height)
end

function meta:CaptureMouse()
	if not self.mouse_captured then
		CG.CGDisplayHideCursor(0)
		CG.CGAssociateMouseAndMouseCursorPosition(false)
		self.cursor_hidden = true
		self.mouse_captured = true
		-- Reset delta tracking
		self.last_mouse_x = nil
		self.last_mouse_y = nil
	end
end

function meta:ReleaseMouse()
	if self.mouse_captured then
		CG.CGAssociateMouseAndMouseCursorPosition(true)
		CG.CGDisplayShowCursor(0)
		self.cursor_hidden = false
		self.mouse_captured = false
		self.last_mouse_x = nil
		self.last_mouse_y = nil
	end
end

function meta:IsMouseCaptured()
	return self.mouse_captured
end

return cocoa
