local ffi = require("ffi")
local wayland = require("bindings.wayland.core")
local xdg_decoration = require("bindings.wayland.xdg_decoration")
local pointer_constraints = require("bindings.wayland.pointer_constraints")
local relative_pointer = require("bindings.wayland.relative_pointer")
local Vec2 = require("structs.vec2")
local system = require("system")
local event = require("event")
-- Expose libraries
-- Constants
wayland.PROT_READ = 1
wayland.MAP_PRIVATE = 2
wayland.XKB_CONTEXT_NO_FLAGS = 0
wayland.XKB_KEYMAP_FORMAT_TEXT_V1 = 1
wayland.XKB_KEYMAP_COMPILE_NO_FLAGS = 0
-- Global active windows table for callbacks
wayland._active_windows = {}
local keycodes = {
	-- Special keys
	[1] = "escape",
	[14] = "backspace",
	[15] = "tab",
	[28] = "enter",
	[57] = "space",
	[58] = "caps_lock",
	[69] = "num_lock",
	[70] = "scroll_lock",
	[99] = "print_screen",
	[110] = "insert",
	[111] = "delete",
	[119] = "pause",
	-- Numbers (Row above letters)
	[2] = "1",
	[3] = "2",
	[4] = "3",
	[5] = "4",
	[6] = "5",
	[7] = "6",
	[8] = "7",
	[9] = "8",
	[10] = "9",
	[11] = "0",
	-- Punctuation
	[12] = "minus",
	[13] = "equal",
	[26] = "left_bracket",
	[27] = "right_bracket",
	[39] = "semicolon",
	[40] = "apostrophe",
	[41] = "grave_accent",
	[43] = "backslash",
	[51] = "comma",
	[52] = "period",
	[53] = "slash",
	-- Alphanumeric (QWERTY)
	[16] = "q",
	[17] = "w",
	[18] = "e",
	[19] = "r",
	[20] = "t",
	[21] = "y",
	[22] = "u",
	[23] = "i",
	[24] = "o",
	[25] = "p",
	[30] = "a",
	[31] = "s",
	[32] = "d",
	[33] = "f",
	[34] = "g",
	[35] = "h",
	[36] = "j",
	[37] = "k",
	[38] = "l",
	[44] = "z",
	[45] = "x",
	[46] = "c",
	[47] = "v",
	[48] = "b",
	[49] = "n",
	[50] = "m",
	-- Modifiers
	[29] = "left_control",
	[42] = "left_shift",
	[56] = "left_alt",
	[54] = "right_shift",
	[97] = "right_control",
	[100] = "right_alt",
	[125] = "left_super", -- Often Windows/Command key
	[126] = "right_super",
	-- Function keys
	[59] = "f1",
	[60] = "f2",
	[61] = "f3",
	[62] = "f4",
	[63] = "f5",
	[64] = "f6",
	[65] = "f7",
	[66] = "f8",
	[67] = "f9",
	[68] = "f10",
	[87] = "f11",
	[88] = "f12",
	-- Navigation
	[102] = "home",
	[103] = "up",
	[104] = "pageup",
	[105] = "left",
	[106] = "right",
	[107] = "end",
	[108] = "down",
	[109] = "pagedown",
}
local cursor_map = {
	arrow = "left_ptr",
	hand = "hand2",
	text_input = "xterm",
	crosshair = "crosshair",
	vertical_resize = "v_double_arrow",
	horizontal_resize = "h_double_arrow",
	top_right_resize = "top_right_corner",
	bottom_left_resize = "bottom_left_corner",
	top_left_resize = "top_left_corner",
	bottom_right_resize = "bottom_right_corner",
	all_resize = "fleur",
}
return function(META)
	-- Button translation from wayland to window system
	local button_translate = {
		[0x110] = "button_1", -- BTN_LEFT
		[0x111] = "button_2", -- BTN_RIGHT
		[0x112] = "button_3", -- BTN_MIDDLE
	}

	function META:Initialize()
		-- Connect to display
		self.display = wayland.wl_client.wl_display_connect(nil)

		if self.display == nil then
			error("Failed to connect to Wayland display")
		end

		-- Initialize state
		self.compositor = nil
		self.seat = nil
		self.shm = nil
		self.pointer = nil
		self.keyboard = nil
		self.surface = nil
		self.xdg_wm_base = nil
		self.xdg_surface = nil
		self.xdg_toplevel = nil
		self.pointer_constraints_manager = nil
		self.relative_pointer_manager = nil
		self.locked_pointer = nil
		self.relative_pointer_obj = nil
		self.xkb_context = wayland.xkb.xkb_context_new(wayland.XKB_CONTEXT_NO_FLAGS)
		self.events = {}
		self.width = (self.Size and self.Size.x > 0) and self.Size.x or 800
		self.height = (self.Size and self.Size.y > 0) and self.Size.y or 600
		self.configured = false
		self.focused = false
		self.mouse_captured = false
		self.mouse_delta = Vec2(0, 0)
		self.repeat_rate = 33
		self.repeat_delay = 500
		-- Register window for callbacks
		local self_ptr = tonumber(tostring(self):match("0x(%x+)"), 16) or math.random(1000000)
		wayland._active_windows[self_ptr] = self
		self._ptr = self_ptr
		-- Get registry
		self.registry = self.display:get_registry()
		-- Registry listener
		self.registry:add_listener(
			{
				global = function(data, registry_proxy, name, interface, version)
					local iface = ffi.string(interface)
					local wnd = wayland._active_windows[tonumber(ffi.cast("intptr_t", data))]

					if not wnd then return end

					-- Cast registry_proxy to wl_registry to access bind method
					local registry = ffi.cast("struct wl_registry*", registry_proxy)

					if iface == "wl_compositor" then
						wnd.compositor = registry:bind(name, wayland.get_interface("wl_compositor"), math.min(version, 4))
						wnd.compositor = ffi.cast("struct wl_compositor*", wnd.compositor)
					elseif iface == "wl_seat" then
						wnd.seat = registry:bind(name, wayland.get_interface("wl_seat"), math.min(version, 5))
						wnd.seat = ffi.cast("struct wl_seat*", wnd.seat)
						wnd:setup_seat_listener()
					elseif iface == "wl_shm" then
						wnd.shm = registry:bind(name, wayland.get_interface("wl_shm"), 1)
						wnd.shm = ffi.cast("struct wl_shm*", wnd.shm)
					elseif iface == "xdg_wm_base" then
						wnd.xdg_wm_base = registry:bind(name, wayland.get_xdg_interface("xdg_wm_base"), 1)
						wnd.xdg_wm_base = ffi.cast("struct xdg_wm_base*", wnd.xdg_wm_base)
						wnd:setup_xdg_wm_base_listener()
					elseif iface == "zxdg_decoration_manager_v1" then
						wnd.decoration_manager = registry:bind(name, xdg_decoration.get_interface("zxdg_decoration_manager_v1"), 1)
						wnd.decoration_manager = ffi.cast("struct zxdg_decoration_manager_v1*", wnd.decoration_manager)
					elseif iface == "zwp_pointer_constraints_v1" then
						wnd.pointer_constraints_manager = registry:bind(name, pointer_constraints.get_interface("zwp_pointer_constraints_v1"), 1)
						wnd.pointer_constraints_manager = ffi.cast("struct zwp_pointer_constraints_v1*", wnd.pointer_constraints_manager)
					elseif iface == "zwp_relative_pointer_manager_v1" then
						wnd.relative_pointer_manager = registry:bind(name, relative_pointer.get_interface("zwp_relative_pointer_manager_v1"), 1)
						wnd.relative_pointer_manager = ffi.cast("struct zwp_relative_pointer_manager_v1*", wnd.relative_pointer_manager)
					end
				end,
				global_remove = function(data, registry, name) end,
			},
			ffi.cast("void*", self_ptr)
		)
		-- Roundtrip to get globals
		wayland.wl_client.wl_display_roundtrip(self.display)
		wayland.wl_client.wl_display_roundtrip(self.display)

		if not self.compositor then error("No compositor found") end

		if not self.xdg_wm_base then error("XDG WM Base not found") end

		-- Open the window
		self:OpenWindow()
		-- Cache values
		self.cached_pos = nil
		self.cached_size = nil
		self.cached_fb_size = nil
		self.last_mouse_pos = Vec2(0, 0)

		-- Add event handlers
		if not system.disable_window then
			self:AddGlobalEvent("Update")
			self:AddGlobalEvent("FrameEnd")
		end

		return true
	end

	function META:OpenWindow()
		-- Create surface
		self.surface_proxy = self.compositor:create_surface()
		self.surface = ffi.cast("struct wl_surface*", self.surface_proxy)
		local iface = ffi.C.wl_proxy_get_interface(ffi.cast("struct wl_proxy*", self.surface_proxy))
		self.xdg_surface = self.xdg_wm_base:get_xdg_surface(self.surface_proxy)
		self.xdg_surface = ffi.cast("struct xdg_surface*", self.xdg_surface)
		self:setup_xdg_surface_listener()
		-- Create toplevel
		self.xdg_toplevel = self.xdg_surface:get_toplevel()
		self.xdg_toplevel = ffi.cast("struct xdg_toplevel*", self.xdg_toplevel)
		self:setup_xdg_toplevel_listener()

		-- Set title if provided
		if self.Title then self.xdg_toplevel:set_title(tostring(self.Title)) end

		-- Request server-side decorations
		if self.decoration_manager then
			self.decoration = self.decoration_manager:get_toplevel_decoration(self.xdg_toplevel)
			self.decoration = ffi.cast("struct zxdg_toplevel_decoration_v1*", self.decoration)
			self:setup_decoration_listener()
			self.decoration:set_mode(2) --ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE)
		end

		-- Commit
		self.surface_proxy:commit()
		wayland.wl_client.wl_display_roundtrip(self.display)
	end

	function META:setup_xdg_wm_base_listener()
		self.xdg_wm_base:add_listener(
			{
				ping = function(data, xdg_wm_base, serial)
					xdg_wm_base:pong(serial)
				end,
			},
			ffi.cast("void*", self._ptr)
		)
	end

	function META:setup_xdg_surface_listener()
		self.xdg_surface:add_listener(
			{
				configure = function(data, xdg_surface, serial)
					local wnd = wayland._active_windows[tonumber(ffi.cast("intptr_t", data))]

					if not wnd then return end

					xdg_surface:ack_configure(serial)
					wnd.configured = true

					if wnd.surface then wnd.surface:commit() end
				end,
			},
			ffi.cast("void*", self._ptr)
		)
	end

	function META:setup_xdg_toplevel_listener()
		self.xdg_toplevel:add_listener(
			{
				configure = function(data, xdg_toplevel, width, height, states)
					local wnd = wayland._active_windows[tonumber(ffi.cast("intptr_t", data))]

					if not wnd then return end

					if width > 0 and height > 0 then
						wnd.width = width
						wnd.height = height
						table.insert(wnd.events, {type = "window_resize", width = width, height = height})
					end
				end,
				close = function(data, xdg_toplevel)
					local wnd = wayland._active_windows[tonumber(ffi.cast("intptr_t", data))]

					if not wnd then return end

					table.insert(wnd.events, {type = "window_close"})
				end,
			},
			ffi.cast("void*", self._ptr)
		)
	end

	function META:setup_decoration_listener()
		self.decoration:add_listener(
			{
				configure = function(data, decoration, mode) -- We don't really need to do anything here, just acknowledge it
				end,
			},
			ffi.cast("void*", self._ptr)
		)
	end

	function META:setup_seat_listener()
		self.seat:add_listener(
			{
				capabilities = function(data, seat_proxy, capabilities)
					local wnd = wayland._active_windows[tonumber(ffi.cast("intptr_t", data))]

					if not wnd then return end

					local seat = ffi.cast("struct wl_seat*", seat_proxy)

					if bit.band(capabilities, 1) ~= 0 and not wnd.pointer then
						wnd.pointer = seat:get_pointer()
						wnd.pointer = ffi.cast("struct wl_pointer*", wnd.pointer)
						wnd:setup_pointer_listener()
					end

					if bit.band(capabilities, 2) ~= 0 and not wnd.keyboard then
						wnd.keyboard = seat:get_keyboard()
						wnd.keyboard = ffi.cast("struct wl_keyboard*", wnd.keyboard)
						wnd:setup_keyboard_listener()
					end
				end,
				name = function(data, seat, name) end,
			},
			ffi.cast("void*", self._ptr)
		)
	end

	function META:setup_pointer_listener()
		self.pointer:add_listener(
			{
				enter = function(data, pointer, serial, surface, x, y)
					local wnd = wayland._active_windows[tonumber(ffi.cast("intptr_t", data))]

					if not wnd then return end

					-- Store serial for cursor operations
					wnd.pointer_serial = serial
					-- Apply current cursor
					wnd:SetCursor(wnd.Cursor)
					table.insert(wnd.events, {type = "cursor_enter"})
				end,
				leave = function(data, pointer, serial, surface)
					local wnd = wayland._active_windows[tonumber(ffi.cast("intptr_t", data))]

					if not wnd then return end

					table.insert(wnd.events, {type = "cursor_leave"})
				end,
				motion = function(data, pointer, time, x, y)
					local wnd = wayland._active_windows[tonumber(ffi.cast("intptr_t", data))]

					if not wnd then return end

					local new_x = tonumber(x)
					local new_y = tonumber(y)
					-- Calculate delta
					local delta_x = new_x - (wnd.mouse_x or new_x)
					local delta_y = new_y - (wnd.mouse_y or new_y)
					wnd.mouse_x = new_x
					wnd.mouse_y = new_y
					table.insert(
						wnd.events,
						{
							type = "mouse_move",
							x = wnd.mouse_x,
							y = wnd.mouse_y,
							delta_x = delta_x,
							delta_y = delta_y,
						}
					)
				end,
				button = function(data, pointer, serial, time, button, state)
					local wnd = wayland._active_windows[tonumber(ffi.cast("intptr_t", data))]

					if not wnd then return end

					table.insert(
						wnd.events,
						{
							type = "mouse_button",
							button = tonumber(button),
							action = state == 1 and "pressed" or "released",
						}
					)
				end,
				axis = function(data, pointer, time, axis, value)
					local wnd = wayland._active_windows[tonumber(ffi.cast("intptr_t", data))]

					if not wnd then return end

					local dx, dy = 0, 0

					if axis == 0 then dy = tonumber(value) else dx = tonumber(value) end

					table.insert(wnd.events, {type = "mouse_scroll", delta_x = dx / 10, delta_y = dy / 10})
				end,
				frame = function(data, pointer) end,
				axis_source = function(data, pointer, axis_source) end,
				axis_stop = function(data, pointer, time, axis) end,
				axis_discrete = function(data, pointer, axis, discrete) end,
			},
			ffi.cast("void*", self._ptr)
		)
	end

	function META:setup_keyboard_listener()
		self.keyboard:add_listener(
			{
				keymap = function(data, keyboard, format, fd, size)
					local wnd = wayland._active_windows[tonumber(ffi.cast("intptr_t", data))]

					if not wnd then return end

					if format == wayland.XKB_KEYMAP_FORMAT_TEXT_V1 then
						local map = ffi.C.mmap(nil, tonumber(size), wayland.PROT_READ, wayland.MAP_PRIVATE, fd, 0)

						if map ~= ffi.cast("void*", -1) then
							wnd.xkb_keymap = wayland.xkb.xkb_keymap_new_from_string(
								wnd.xkb_context,
								ffi.cast("const char*", map),
								wayland.XKB_KEYMAP_FORMAT_TEXT_V1,
								wayland.XKB_KEYMAP_COMPILE_NO_FLAGS
							)
							ffi.C.munmap(map, tonumber(size))

							if wnd.xkb_state then wayland.xkb.xkb_state_unref(wnd.xkb_state) end

							wnd.xkb_state = wayland.xkb.xkb_state_new(wnd.xkb_keymap)
						end
					end

					ffi.C.close(fd)
				end,
				enter = function(data, keyboard, serial, surface, keys)
					local wnd = wayland._active_windows[tonumber(ffi.cast("intptr_t", data))]

					if not wnd then return end

					table.insert(wnd.events, {type = "window_focus", focused = true})
				end,
				leave = function(data, keyboard, serial, surface)
					local wnd = wayland._active_windows[tonumber(ffi.cast("intptr_t", data))]

					if not wnd then return end

					wnd.repeat_key = nil
					table.insert(wnd.events, {type = "window_focus", focused = false})
				end,
				key = function(data, keyboard, serial, time, key, state)
					local wnd = wayland._active_windows[tonumber(ffi.cast("intptr_t", data))]

					if not wnd then return end

					local key_name = keycodes[tonumber(key)] or "unknown"
					local char = nil

					if state == 1 and wnd.xkb_state then
						local buffer = ffi.new("char[64]")
						local len = wayland.xkb.xkb_state_key_get_utf8(wnd.xkb_state, key + 8, buffer, 64)

						if len > 0 then char = ffi.string(buffer) end
					end

					table.insert(
						wnd.events,
						{type = state == 1 and "key_press" or "key_release", key = key_name, char = char}
					)

					-- Handle repeat state
					if state == 1 then
						wnd.repeat_key = {key = key, key_name = key_name, char = char}
						wnd.repeat_next_time = (system.GetTimeNS() / 1e6) + (wnd.repeat_delay or 500)
					elseif wnd.repeat_key and wnd.repeat_key.key == key then
						wnd.repeat_key = nil
					end
				end,
				modifiers = function(data, keyboard, serial, depressed, latched, locked, group)
					local wnd = wayland._active_windows[tonumber(ffi.cast("intptr_t", data))]

					if wnd and wnd.xkb_state then
						wayland.xkb.xkb_state_update_mask(wnd.xkb_state, depressed, latched, locked, 0, 0, group)
					end
				end,
				repeat_info = function(data, keyboard, rate, delay)
					local wnd = wayland._active_windows[tonumber(ffi.cast("intptr_t", data))]

					if wnd then
						wnd.repeat_rate = rate
						wnd.repeat_delay = delay
					end
				end,
			},
			ffi.cast("void*", self._ptr)
		)
	end

	function META:PreWindowSetup() -- Called before window setup - can be overridden
	end

	function META:PostWindowSetup() -- Called after window setup - can be overridden
	end

	function META:OnFrameEnd() -- Process events and update
	end

	function META:OnPostUpdate(dt) end

	function META:OnUpdate(dt)
		self:SetMouseDelta(Vec2(0, 0))
		-- Read all events from wayland
		local events = self:ReadEvents()

		-- Handle character/key repeats
		if self.repeat_key and self.repeat_rate and self.repeat_rate > 0 then
			local now = system.GetTimeNS() / 1e6

			while self.repeat_key and now >= self.repeat_next_time do
				table.insert(
					events,
					{
						type = "key_press",
						key = self.repeat_key.key_name,
						char = self.repeat_key.char,
						is_repeat = true,
					}
				)
				self.repeat_next_time = self.repeat_next_time + (1000 / self.repeat_rate)
			end
		end

		for _, event in ipairs(events) do
			if event.type == "key_press" then
				-- Fire key down event
				self:CallEvent("KeyInput", event.key, true)

				-- Fire character input if available
				if event.char and event.char ~= "" then
					self:CallEvent("CharInput", event.char)
				end
			elseif event.type == "key_release" then
				self:CallEvent("KeyInput", event.key, false)
			elseif event.type == "mouse_button" then
				local button = button_translate[event.button] or "button_" .. tostring(event.button)
				local pressed = event.action == "pressed"
				self:CallEvent("MouseInput", button, pressed)
			elseif event.type == "mouse_move" then
				-- Update mouse position
				self.last_mouse_pos = Vec2(event.x, event.y)
				self:CallEvent("CursorPosition", self.last_mouse_pos)

				-- Always set delta from motion events
				if event.delta_x and event.delta_y then
					self:SetMouseDelta(Vec2(event.delta_x, event.delta_y))
				end
			elseif event.type == "mouse_move_relative" then
				-- Handle relative motion from locked pointer
				if event.delta_x and event.delta_y then
					self:SetMouseDelta(Vec2(event.delta_x, event.delta_y))
				end
			elseif event.type == "mouse_scroll" then
				self:CallEvent("MouseScroll", Vec2(event.delta_x, event.delta_y))
			elseif event.type == "window_close" then
				self:CallEvent("Close")
			elseif event.type == "window_resize" then
				self.cached_size = nil
				self.cached_fb_size = nil
				self:CallEvent("SizeChanged", Vec2(event.width, event.height))
				self:CallEvent("FramebufferResized", Vec2(event.width, event.height))
			elseif event.type == "window_focus" then
				self.focused = event.focused
				self:CallEvent(event.focused and "GainedFocus" or "LostFocus")
			elseif event.type == "cursor_enter" then
				self:CallEvent("CursorEnter")
			elseif event.type == "cursor_leave" then
				self:CallEvent("CursorLeave")
			end
		end

		self:OnPostUpdate(dt)
	-- Note: Wayland doesn't support cursor warping, so trapped cursor
	-- relies on the compositor's pointer constraints protocol.
	-- For now, mouse capture works via delta tracking and cursor hiding.
	-- When the pointer leaves the window, we stop receiving events,
	-- but delta tracking continues when it re-enters.
	end

	function META:ReadEvents()
		-- Dispatch any pending events first
		wayland.wl_client.wl_display_dispatch_pending(self.display)
		-- Flush outgoing requests
		wayland.wl_client.wl_display_flush(self.display)
		-- Check if there are any events to read (non-blocking)
		local pollfd = ffi.new("struct pollfd[1]")
		pollfd[0].fd = wayland.wl_client.wl_display_get_fd(self.display)
		pollfd[0].events = 1 -- POLLIN
		-- Poll with 0 timeout for non-blocking check
		if ffi.C.poll(pollfd, 1, 0) > 0 then
			-- Events available, prepare to read
			if wayland.wl_client.wl_display_prepare_read(self.display) == 0 then
				-- Read the events
				wayland.wl_client.wl_display_read_events(self.display)
				-- Dispatch the events we just read
				wayland.wl_client.wl_display_dispatch_pending(self.display)
			else
				-- Failed to prepare, dispatch pending instead
				wayland.wl_client.wl_display_dispatch_pending(self.display)
			end
		end

		-- Return collected events and clear the queue
		local events = self.events
		self.events = {}
		return events
	end

	function META:OnRemove()
		if self.display then
			-- Release mouse if captured
			if self:IsMouseCaptured() then self:ReleaseMouse() end

			-- Clean up wayland resources
			if self.locked_pointer then self.locked_pointer:destroy() end

			if self.relative_pointer_obj then self.relative_pointer_obj:destroy() end

			if self.xdg_toplevel then self.xdg_toplevel:destroy() end

			if self.xdg_surface then self.xdg_surface:destroy() end

			if self.surface_proxy then self.surface_proxy:destroy() end

			if self.cursor_surface then self.cursor_surface:destroy() end

			if self.cursor_theme then
				wayland.wl_cursor.wl_cursor_theme_destroy(self.cursor_theme)
			end

			wayland.wl_client.wl_display_disconnect(self.display)

			-- Remove from active windows
			if self._ptr then wayland._active_windows[self._ptr] = nil end
		end
	end

	function META:Maximize()
		-- XDG toplevel maximize
		-- Would need to implement xdg_toplevel.set_maximized
		error("nyi: Maximize not implemented in wayland bindings", 2)
	end

	function META:Minimize()
		-- XDG toplevel minimize
		-- Would need to implement xdg_toplevel.set_minimized
		error("nyi: Minimize not implemented in wayland bindings", 2)
	end

	function META:Restore()
		-- XDG toplevel unset maximize/fullscreen
		error("nyi: Restore not implemented in wayland bindings", 2)
	end

	function META:SetCursor(mode)
		if not self.Cursors[mode] then mode = "arrow" end

		self.Cursor = mode

		if mode == "hidden" then
			if self.pointer and self.pointer_serial then
				self.pointer:set_cursor(self.pointer_serial, nil, 0, 0)
			end
		else
			if self.pointer and self.pointer_serial then
				if not self.cursor_theme then
					self.cursor_theme = wayland.wl_cursor.wl_cursor_theme_load(nil, 32, self.shm)
				end

				local name = cursor_map[mode] or "left_ptr"
				local cursor = wayland.wl_cursor.wl_cursor_theme_get_cursor(self.cursor_theme, name)

				if cursor ~= nil then
					local image = cursor.images[0]
					local buffer = wayland.wl_cursor.wl_cursor_image_get_buffer(image)

					if not self.cursor_surface then
						self.cursor_surface = self.compositor:create_surface()
					end

					self.cursor_surface:attach(buffer, 0, 0)
					self.cursor_surface:damage(0, 0, image.width, image.height)
					self.cursor_surface:commit()
					self.pointer:set_cursor(self.pointer_serial, self.cursor_surface, image.hotspot_x, image.hotspot_y)
				end
			end
		end
	end

	function META:GetPosition()
		if not self.cached_pos then
			-- Wayland doesn't expose global window position for security
			-- Return (0, 0) as a placeholder
			self.cached_pos = Vec2(0, 0)
		end

		return self.cached_pos
	end

	function META:SetPosition(pos)
		self.cached_pos = nil
		-- Wayland doesn't allow clients to position their own windows
		-- This is controlled by the compositor
		error("nyi: SetPosition not supported in Wayland (compositor controlled)", 2)
	end

	function META:GetSize()
		if not self.cached_size then
			self.cached_size = Vec2(self.width, self.height)
		end

		return self.cached_size
	end

	function META:SetSize(size)
		self.cached_size = nil
		self.cached_fb_size = nil
		-- Update internal size
		self.width = size.x
		self.height = size.y
	-- Note: In Wayland, size is typically controlled by the compositor
	-- We can request a size, but the compositor may override it
	-- This would be done through xdg_toplevel configure events
	end

	function META:GetFramebufferSize()
		if not self.cached_fb_size then
			-- On Wayland, framebuffer size matches window size
			-- unless dealing with HiDPI (scale factor)
			self.cached_fb_size = Vec2(self.width, self.height)
		end

		return self.cached_fb_size
	end

	function META:SetTitle(title)
		if self.xdg_toplevel then self.xdg_toplevel:set_title(tostring(title)) end
	end

	function META:GetMousePosition()
		-- Return cached mouse position from move events
		return self.last_mouse_pos
	end

	function META:SetMousePosition(pos)
		-- Wayland doesn't allow clients to warp the pointer
		-- This is a security feature
		error("nyi: SetMousePosition not supported in Wayland (security restriction)", 2)
	end

	function META:GetSurfaceHandle()
		return self.surface, self.display
	end

	function META:IsFocused()
		return self.focused
	end

	function META:SetClipboard(text)
		-- Would need to implement wl_data_device protocol
		error("nyi: SetClipboard not implemented in wayland bindings", 2)
	end

	function META:GetClipboard()
		-- Would need to implement wl_data_device protocol
		error("nyi: GetClipboard not implemented in wayland bindings", 2)
	end

	function META:SwapInterval(interval) -- Wayland doesn't have explicit vsync control
	-- The compositor handles presentation timing
	-- This is a no-op on Wayland
	end

	function META:CaptureMouse()
		-- Hide cursor by setting null cursor surface
		if self.pointer and self.pointer_serial then
			self.pointer:set_cursor(self.pointer_serial, nil, 0, 0)
		end

		-- Create relative pointer to receive delta events
		if self.relative_pointer_manager and self.pointer and not self.relative_pointer_obj then
			local pointer_proxy = ffi.cast("struct wl_proxy*", self.pointer)
			self.relative_pointer_obj = self.relative_pointer_manager:get_relative_pointer(pointer_proxy)
			self.relative_pointer_obj = ffi.cast("struct zwp_relative_pointer_v1*", self.relative_pointer_obj)
			-- Setup listener for relative motion events
			self.relative_pointer_obj:add_listener(
				{
					relative_motion = function(data, relative_pointer, utime_hi, utime_lo, dx, dy, dx_unaccel, dy_unaccel)
						local wnd = wayland._active_windows[tonumber(ffi.cast("intptr_t", data))]

						if not wnd then return end

						-- Use unaccelerated delta for raw input
						local delta_x = tonumber(dx_unaccel)
						local delta_y = tonumber(dy_unaccel)
						table.insert(wnd.events, {type = "mouse_move_relative", delta_x = delta_x, delta_y = delta_y})
					end,
				},
				ffi.cast("void*", self._ptr)
			)
		end

		-- Lock pointer to get relative motion events without position constraints
		if
			self.pointer_constraints_manager and
			self.surface_proxy and
			self.pointer and
			not self.locked_pointer
		then
			local pointer_proxy = ffi.cast("struct wl_proxy*", self.pointer)
			self.locked_pointer = self.pointer_constraints_manager:lock_pointer(self.surface_proxy, pointer_proxy, nil, -- region (nil = entire surface)
			2 -- lifetime: persistent (ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_PERSISTENT)
			)
			self.locked_pointer = ffi.cast("struct zwp_locked_pointer_v1*", self.locked_pointer)
		end

		self.mouse_captured = true
	end

	function META:ReleaseMouse()
		self.mouse_captured = false

		-- Destroy the locked pointer to release the constraint
		if self.locked_pointer then
			self.locked_pointer:destroy()
			self.locked_pointer = nil
		end

		-- Destroy relative pointer
		if self.relative_pointer_obj then
			self.relative_pointer_obj:destroy()
			self.relative_pointer_obj = nil
		end
	-- Show cursor again by not setting it (compositor will use default)
	-- We'd need a proper cursor surface to set a visible cursor
	-- For now, cursor will show automatically when not captured
	end

	function META:IsMouseCaptured()
		return self.mouse_captured
	end
end
