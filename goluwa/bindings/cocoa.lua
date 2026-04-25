local ffi = require("ffi")
local objc = import("goluwa/bindings/objc.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local cocoa = {}
-- Load required frameworks
objc.loadFramework("Cocoa")
objc.loadFramework("QuartzCore")
local cocoa_objc = objc.bind({
	classes = {
		"NSArray",
		"NSDate",
		"NSApplication",
		"NSAutoreleasePool",
		"NSCursor",
		"NSPasteboard",
		"NSString",
		"NSMutableArray",
		"NSView",
		"NSWindow",
		"CAMetalLayer",
	},
	methods = {
		NSObject = {
			class = {
				alloc = {types = "@#:", unbound = true},
			},
			instance = {
				init = "@@:",
			},
		},
		NSArray = {
			instance = {
				count = "Q@:",
				objectAtIndex = {selector = "objectAtIndex:", types = "@@:Q"},
			},
		},
		NSDate = {
			class = {
				distantPast = "@#:",
			},
		},
		NSApplication = {
			class = {
				sharedApplication = "@#:",
			},
			instance = {
				activateIgnoringOtherApps = {selector = "activateIgnoringOtherApps:", types = "v@:B"},
				finishLaunching = "v@:",
				nextEventMatchingMask_untilDate_inMode_dequeue = {
					selector = "nextEventMatchingMask:untilDate:inMode:dequeue:",
					types = "@@:Q@@B",
				},
				sendEvent = {selector = "sendEvent:", types = "v@:@"},
				setActivationPolicy = {selector = "setActivationPolicy:", types = "v@:q"},
				updateWindows = "v@:",
			},
		},
		NSCursor = {
			class = {
				arrowCursor = "@#:",
				closedHandCursor = "@#:",
				crosshairCursor = "@#:",
				IBeamCursor = "@#:",
				openHandCursor = "@#:",
				pointingHandCursor = "@#:",
				resizeLeftRightCursor = "@#:",
				resizeUpDownCursor = "@#:",
			},
			instance = {
				set = "v@:",
			},
		},
		NSDraggingInfo = {
			instance = {
				draggingPasteboard = "@@:",
			},
		},
		NSEvent = {
			instance = {
				characters = "@@:",
				deltaX = "d@:",
				deltaY = "d@:",
				isARepeat = "B@:",
				keyCode = "Q@:",
				locationInWindow = "{CGPoint=dd}@:",
				modifierFlags = "Q@:",
				scrollingDeltaX = "d@:",
				scrollingDeltaY = "d@:",
				type = "q@:",
			},
		},
		NSPasteboard = {
			instance = {
				propertyListForType = {selector = "propertyListForType:", types = "@@:@"},
				stringForType = {selector = "stringForType:", types = "@@:@"},
			},
		},
		NSString = {
			class = {
				stringWithUTF8String = {selector = "stringWithUTF8String:", types = "@#:*"},
			},
			instance = {
				UTF8String = "*@:",
			},
		},
		NSMutableArray = {
			class = {
				array = "@#:",
			},
			instance = {
				addObject = {selector = "addObject:", types = "v@:@"},
			},
		},
		NSView = {
			instance = {
				bounds = "{CGRect={CGPoint=dd}{CGSize=dd}}@:",
				initWithFrame = {selector = "initWithFrame:", types = "@@:{CGRect={CGPoint=dd}{CGSize=dd}}"},
				registerForDraggedTypes = {selector = "registerForDraggedTypes:", types = "v@:@"},
				setLayer = {selector = "setLayer:", types = "v@:@"},
				setWantsLayer = {selector = "setWantsLayer:", types = "v@:B"},
				unregisterDraggedTypes = "v@:",
			},
		},
		NSWindow = {
			instance = {
				contentView = "@@:",
				convertPointToScreen = {selector = "convertPointToScreen:", types = "{CGPoint=dd}@:{CGPoint=dd}"},
				deminiaturize = {selector = "deminiaturize:", types = "v@:@"},
				frame = "{CGRect={CGPoint=dd}{CGSize=dd}}@:",
				initWithContentRect_styleMask_backing_defer = {
					selector = "initWithContentRect:styleMask:backing:defer:",
					types = "@@:{CGRect={CGPoint=dd}{CGSize=dd}}QqB",
				},
				isKeyWindow = "B@:",
				isMiniaturized = "B@:",
				isVisible = "B@:",
				isZoomed = "B@:",
				makeKeyAndOrderFront = {selector = "makeKeyAndOrderFront:", types = "v@:@"},
				miniaturize = {selector = "miniaturize:", types = "v@:@"},
				mouseLocationOutsideOfEventStream = "{CGPoint=dd}@:",
				setContentView = {selector = "setContentView:", types = "v@:@"},
				setDelegate = {selector = "setDelegate:", types = "v@:@"},
				setTitle = {selector = "setTitle:", types = "v@:@"},
				zoom = {selector = "zoom:", types = "v@:@"},
			},
		},
		CAMetalLayer = {
			class = {
				layer = "@#:",
			},
			instance = {
				setDrawableSize = {selector = "setDrawableSize:", types = "v@:{CGSize=dd}"},
			},
		},
	},
})
local classes = cocoa_objc.classes
local NSObject = cocoa_objc.methods.NSObject
local NSArray = cocoa_objc.methods.NSArray
local NSDate = cocoa_objc.methods.NSDate
local NSApplication = cocoa_objc.methods.NSApplication
local NSCursor = cocoa_objc.methods.NSCursor
local NSDraggingInfo = cocoa_objc.methods.NSDraggingInfo
local NSEvent = cocoa_objc.methods.NSEvent
local NSPasteboard = cocoa_objc.methods.NSPasteboard
local NSString = cocoa_objc.methods.NSString
local NSMutableArray = cocoa_objc.methods.NSMutableArray
local NSView = cocoa_objc.methods.NSView
local NSWindow = cocoa_objc.methods.NSWindow
local CAMetalLayer = cocoa_objc.methods.CAMetalLayer
local nil_id = objc["nil"]
-- Create a custom window delegate class to handle close events
local WindowDelegate = nil
local DropView = nil
local close_flags = {} -- Store close state per window
local drop_queues = {}

local function pointer_key(obj)
	return tonumber(ffi.cast("intptr_t", obj))
end

local function decode_uri_component(str)
	return (str:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end))
end

local function parse_file_uri(uri)
	if uri:sub(1, 7) ~= "file://" then return nil end

	local host, path = uri:match("^file://([^/]*)(/.*)$")

	if not path then return nil end

	if host ~= "" and host ~= "localhost" then return nil end

	return decode_uri_component(path)
end

local function extract_dropped_paths(dragging_info)
	if dragging_info == nil or dragging_info == objc.ptr(nil) then return nil end

	local pasteboard = NSDraggingInfo.draggingPasteboard(dragging_info)

	if pasteboard == nil or pasteboard == objc.ptr(nil) then return nil end

	local filenames_type = NSString.stringWithUTF8String("NSFilenamesPboardType")
	local filenames = NSPasteboard.propertyListForType(pasteboard, filenames_type)
	local paths = {}

	if filenames ~= nil and filenames ~= objc.ptr(nil) then
		local count = tonumber(NSArray.count(filenames)) or 0

		for index = 0, count - 1 do
			local entry = NSArray.objectAtIndex(filenames, index)

			if entry ~= nil and entry ~= objc.ptr(nil) then
				local cstr = NSString.UTF8String(entry)

				if cstr ~= nil then table.insert(paths, ffi.string(cstr)) end
			end
		end
	end

	if #paths > 0 then return paths end

	local file_url_type = NSString.stringWithUTF8String("public.file-url")
	local file_url = NSPasteboard.stringForType(pasteboard, file_url_type)

	if file_url ~= nil and file_url ~= objc.ptr(nil) then
		local cstr = NSString.UTF8String(file_url)

		if cstr ~= nil then
			local path = parse_file_uri(ffi.string(cstr))

			if path then return {path} end
		end
	end

	return nil
end

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
			local window_ptr = pointer_key(sender)
			close_flags[window_ptr] = true
			return 1 -- YES, allow close
		end
	)

	return WindowDelegate
end

local function setup_drop_view()
	if DropView then return DropView end

	DropView = objc.newClass("LuaDropView", "NSView")

	objc.addMethod(
		DropView,
		"draggingEntered:",
		"Q@:@",
		function(self, sel, sender)
			local paths = extract_dropped_paths(sender)

			if paths and #paths > 0 then return 1 end

			return 0
		end
	)

	objc.addMethod(
		DropView,
		"draggingUpdated:",
		"Q@:@",
		function(self, sel, sender)
			local paths = extract_dropped_paths(sender)

			if paths and #paths > 0 then return 1 end

			return 0
		end
	)

	objc.addMethod(
		DropView,
		"prepareForDragOperation:",
		"B@:@",
		function(self, sel, sender)
			return 1
		end
	)

	objc.addMethod(
		DropView,
		"performDragOperation:",
		"B@:@",
		function(self, sel, sender)
			local paths = extract_dropped_paths(sender)

			if not paths or #paths == 0 then return 0 end

			local key = pointer_key(self)
			drop_queues[key] = drop_queues[key] or {}
			table.insert(drop_queues[key], paths)
			return 1
		end
	)

	return DropView
end

local function CGRectMake(x, y, width, height)
	return ffi.new("CGRect", {{x, y}, {width, height}})
end

local function get_content_height(window)
	if window == nil or window == objc.ptr(nil) then return 0 end

	local content_view = NSWindow.contentView(window)

	if content_view == nil or content_view == objc.ptr(nil) then return 0 end

	local bounds = NSView.bounds(content_view)
	return tonumber(bounds.size.height) or 0
end

local function flip_window_y(window, y)
	return get_content_height(window) - (tonumber(y) or 0)
end

-- Initialize Cocoa application and create window
local function init_cocoa(width, height)
	local pool = NSObject.init(NSObject.alloc(classes.NSAutoreleasePool))
	local app = NSApplication.sharedApplication()
	NSApplication.setActivationPolicy(app, 0)
	NSApplication.activateIgnoringOtherApps(app, true)
	local frame = CGRectMake(100, 100, width, height)
	local styleMask = bit.bor(1, 2, 4, 8)
	local window = NSWindow.initWithContentRect_styleMask_backing_defer(NSObject.alloc(classes.NSWindow), frame, styleMask, 2, false)
	setup_drop_view()
	NSWindow.makeKeyAndOrderFront(window, nil_id)
	local contentView = NSWindow.contentView(window)
	local bounds = NSView.bounds(contentView)
	local dropView = NSView.initWithFrame(NSObject.alloc(DropView), bounds)
	local dragged_types = NSMutableArray.array()
	NSMutableArray.addObject(dragged_types, NSString.stringWithUTF8String("NSFilenamesPboardType"))
	NSMutableArray.addObject(dragged_types, NSString.stringWithUTF8String("public.file-url"))
	NSView.registerForDraggedTypes(dropView, dragged_types)
	NSWindow.setContentView(window, dropView)
	contentView = NSWindow.contentView(window)
	local metal_layer = CAMetalLayer.layer()
	bounds = NSView.bounds(contentView)
	CAMetalLayer.setDrawableSize(metal_layer, bounds.size)
	NSView.setWantsLayer(contentView, true)
	NSView.setLayer(contentView, metal_layer)
	return window, metal_layer, contentView
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

	local event_type = tonumber(NSEvent.type(nsevent))
	local modifier_flags = tonumber(NSEvent.modifierFlags(nsevent))
	-- Extract modifiers
	local modifiers = {
		shift = bit.band(modifier_flags, NSEventModifierFlags.Shift) ~= 0,
		control = bit.band(modifier_flags, NSEventModifierFlags.Control) ~= 0,
		alt = bit.band(modifier_flags, NSEventModifierFlags.Option) ~= 0,
		command = bit.band(modifier_flags, NSEventModifierFlags.Command) ~= 0,
	}

	-- Keyboard events
	if event_type == NSEventType.KeyDown then
		local keycode = tonumber(NSEvent.keyCode(nsevent))
		local key = keycodes[keycode] or "unknown"
		local chars = NSEvent.characters(nsevent)
		local char = nil
		local is_repeat = NSEvent.isARepeat(nsevent) ~= 0

		if chars ~= nil and chars ~= objc.ptr(nil) then
			local cstr = NSString.UTF8String(chars)

			if cstr ~= nil then char = ffi.string(cstr) end
		end

		return {
			type = "key_press",
			key = key,
			char = char,
			is_repeat = is_repeat,
			modifiers = modifiers,
		}
	elseif event_type == NSEventType.KeyUp then
		local keycode = tonumber(NSEvent.keyCode(nsevent))
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
		local location = NSEvent.locationInWindow(nsevent)
		local y = flip_window_y(window, location.y)
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
			y = y,
			modifiers = modifiers,
		}
	elseif
		event_type == NSEventType.LeftMouseUp or
		event_type == NSEventType.RightMouseUp or
		event_type == NSEventType.OtherMouseUp
	then
		local location = NSEvent.locationInWindow(nsevent)
		local y = flip_window_y(window, location.y)
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
			y = y,
			modifiers = modifiers,
		}
	-- Mouse movement
	elseif
		event_type == NSEventType.MouseMoved or
		event_type == NSEventType.LeftMouseDragged or
		event_type == NSEventType.RightMouseDragged or
		event_type == NSEventType.OtherMouseDragged
	then
		local location = NSEvent.locationInWindow(nsevent)
		local delta_x = tonumber(NSEvent.deltaX(nsevent))
		local delta_y = -(tonumber(NSEvent.deltaY(nsevent)) or 0)
		local y = flip_window_y(window, location.y)
		return {
			type = "mouse_move",
			x = tonumber(location.x),
			y = y,
			delta_x = delta_x,
			delta_y = delta_y,
			modifiers = modifiers,
		}
	-- Scroll wheel
	elseif event_type == NSEventType.ScrollWheel then
		local location = NSEvent.locationInWindow(nsevent)
		local y = flip_window_y(window, location.y)
		local delta_x = tonumber(NSEvent.scrollingDeltaX(nsevent))
		local delta_y = tonumber(NSEvent.scrollingDeltaY(nsevent))
		return {
			type = "mouse_scroll",
			x = tonumber(location.x),
			y = y,
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
	local distantPast = NSDate.distantPast()
	local mode = NSString.stringWithUTF8String("kCFRunLoopDefaultMode")
	local event = NSApplication.nextEventMatchingMask_untilDate_inMode_dequeue(
		app,
		NSEventMaskAny,
		distantPast,
		mode,
		dequeue
	)

	if event ~= nil and event ~= objc.ptr(nil) then
		local event_type = tonumber(NSEvent.type(event))
		local converted = convert_nsevent(event, window)

		if converted then table.insert(event_list, converted) end

		if
			event_type ~= NSEventType.KeyDown and
			event_type ~= NSEventType.KeyUp and
			event_type ~= NSEventType.FlagsChanged
		then
			NSApplication.sendEvent(app, event)
		end

		NSApplication.updateWindows(app)
		return true
	end

	return false
end

-- Helper to get the NSApplication singleton
local function get_app()
	return NSApplication.sharedApplication()
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
local cursor_selector_map = {
	arrow = {"arrowCursor"},
	hand = {"pointingHandCursor", "openHandCursor"},
	text_input = {"IBeamCursor"},
	crosshair = {"crosshairCursor"},
	vertical_resize = {"resizeUpDownCursor"},
	horizontal_resize = {"resizeLeftRightCursor"},
	all_resize = {"openHandCursor", "closedHandCursor", "arrowCursor"},
	top_right_resize = {"resizeLeftRightCursor", "resizeUpDownCursor", "arrowCursor"},
	bottom_left_resize = {"resizeLeftRightCursor", "resizeUpDownCursor", "arrowCursor"},
	top_left_resize = {"resizeLeftRightCursor", "resizeUpDownCursor", "arrowCursor"},
	bottom_right_resize = {"resizeLeftRightCursor", "resizeUpDownCursor", "arrowCursor"},
}

local function get_ns_cursor(mode)
	local selectors = cursor_selector_map[mode] or cursor_selector_map.arrow

	for _, selector in ipairs(selectors) do
		local ok, cursor = pcall(function()
			return NSCursor[selector]()
		end)

		if ok and cursor ~= nil then return cursor end
	end

	return NSCursor[cursor_selector_map.arrow[1]]()
end

local meta = {}
meta.__index = meta

function cocoa.window(width, height)
	local self = setmetatable({}, meta)
	self.window, self.metal_layer, self.content_view = init_cocoa(width, height)
	self.last_width = nil
	self.last_height = nil
	self.cursor_hidden = false
	self.mouse_captured = false
	self.cursor_mode = "arrow"
	self.last_mouse_x = nil
	self.last_mouse_y = nil
	return self
end

function meta:Initialize()
	self.app = get_app()
	NSApplication.finishLaunching(self.app)
	setup_window_delegate()
	local delegate = NSObject.init(NSObject.alloc(WindowDelegate))
	NSWindow.setDelegate(self.window, delegate)
	self.window_ptr = pointer_key(self.window)
	self.content_view_ptr = pointer_key(self.content_view)
	close_flags[self.window_ptr] = false
	drop_queues[self.content_view_ptr] = drop_queues[self.content_view_ptr] or {}
end

function meta:SetTitle(str)
	NSWindow.setTitle(self.window, NSString.stringWithUTF8String(str))
end

function meta:OpenWindow()
	NSWindow.makeKeyAndOrderFront(self.window, nil_id)
	NSApplication.activateIgnoringOtherApps(self.app, true)
end

function meta:Minimize()
	NSWindow.miniaturize(self.window, nil_id)
end

function meta:Maximize()
	local is_zoomed = NSWindow.isZoomed(self.window)

	if is_zoomed == nil or is_zoomed == 0 then
		NSWindow.zoom(self.window, nil_id)
	end
end

function meta:Restore()
	local is_miniaturized = NSWindow.isMiniaturized(self.window)

	if is_miniaturized ~= nil and is_miniaturized ~= 0 then
		NSWindow.deminiaturize(self.window, nil_id)
	end

	local is_zoomed = NSWindow.isZoomed(self.window)

	if is_zoomed ~= nil and is_zoomed ~= 0 then
		NSWindow.zoom(self.window, nil_id)
	end
end

function meta:HideCursor()
	if not self.cursor_hidden then
		CG.CGDisplayHideCursor(0)
		self.cursor_hidden = true
	end
end

function meta:ShowCursor()
	if self.cursor_hidden then
		CG.CGDisplayShowCursor(0)
		self.cursor_hidden = false
	end
end

function meta:SetCursor(mode)
	self.cursor_mode = mode or "arrow"

	if self.cursor_mode == "hidden" then
		self:HideCursor()
		return
	end

	if not self.mouse_captured then self:ShowCursor() end

	NSCursor.set(get_ns_cursor(self.cursor_mode))
end

function meta:GetSurfaceHandle()
	return self.metal_layer
end

function meta:GetPosition()
	local frame = NSWindow.frame(self.window)
	return Vec2(tonumber(frame.origin.x), tonumber(frame.origin.y))
end

function meta:GetMousePosition()
	local pos = NSWindow.mouseLocationOutsideOfEventStream(self.window)
	return Vec2(tonumber(pos.x), flip_window_y(self.window, pos.y))
end

function meta:SetMousePosition(pos)
	local local_pos = ffi.new("CGPoint")
	local_pos.x = math.floor(tonumber(pos.x) or 0)
	local_pos.y = math.floor(flip_window_y(self.window, pos.y))
	CG.CGWarpMouseCursorPosition(NSWindow.convertPointToScreen(self.window, local_pos))
end

function meta:IsFocused()
	local focused = NSWindow.isKeyWindow(self.window)
	return focused ~= nil and focused ~= 0
end

function meta:IsMinimized()
	local minimized = NSWindow.isMiniaturized(self.window)
	return minimized ~= nil and minimized ~= 0
end

function meta:IsMaximized()
	local maximized = NSWindow.isZoomed(self.window)
	return maximized ~= nil and maximized ~= 0
end

function meta:IsVisible()
	local isVisible = NSWindow.isVisible(self.window)
	return isVisible ~= nil and isVisible ~= 0
end

function meta:GetSize()
	local window_frame = NSWindow.frame(self.window)
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
		local content_view = NSWindow.contentView(self.window)
		local bounds = NSView.bounds(content_view)
		CAMetalLayer.setDrawableSize(self.metal_layer, bounds.size)
	end

	local drop_queue = drop_queues[self.content_view_ptr]

	if drop_queue and #drop_queue > 0 then
		for _, paths in ipairs(drop_queue) do
			table.insert(events, {type = "drop", paths = paths})
		end

		drop_queues[self.content_view_ptr] = {}
	end

	return events
end

function meta:Destroy()
	close_flags[self.window_ptr] = nil
	drop_queues[self.content_view_ptr] = nil
	NSWindow.setDelegate(self.window, nil_id)
	NSView.unregisterDraggedTypes(self.content_view)
end

function meta:GetWindowSize()
	local window_frame = NSWindow.frame(self.window)
	return tonumber(window_frame.size.width), tonumber(window_frame.size.height)
end

function meta:CaptureMouse()
	if not self.mouse_captured then
		self:HideCursor()
		CG.CGAssociateMouseAndMouseCursorPosition(false)
		self.mouse_captured = true
		-- Reset delta tracking
		self.last_mouse_x = nil
		self.last_mouse_y = nil
	end
end

function meta:ReleaseMouse()
	if self.mouse_captured then
		CG.CGAssociateMouseAndMouseCursorPosition(true)
		self.mouse_captured = false
		self.last_mouse_x = nil
		self.last_mouse_y = nil
		self:SetCursor(self.cursor_mode)
	end
end

function meta:IsMouseCaptured()
	return self.mouse_captured
end

return cocoa
