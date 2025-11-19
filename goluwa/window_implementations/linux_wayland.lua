local ffi = require("ffi")
local wayland = require("bindings.wayland.core")
local Vec2 = require("structs.vec2").Vec2d
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
		self.xkb_context = wayland.xkb.xkb_context_new(wayland.XKB_CONTEXT_NO_FLAGS)
		self.events = {}
		self.width = self.Size and self.Size.x or 800
		self.height = self.Size and self.Size.y or 600
		self.configured = false
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
			self:AddEvent("Update")
			self:AddEvent("FrameEnd")
		end

		return true
	end

	function META:OpenWindow()
		-- Create surface
		self.surface_proxy = self.compositor:create_surface()
		print("Created Wayland surface (proxy):", self.surface_proxy)
		print("  type:", type(self.surface_proxy))
		print("  tostring:", tostring(self.surface_proxy))
		self.surface = ffi.cast("struct wl_surface*", self.surface_proxy)
		print("Created Wayland surface (casted):", self.surface)
		print("  type:", type(self.surface))
		-- Create XDG surface using the proxy object
		print("About to call get_xdg_surface with:", self.surface_proxy)
		print(
			"  Checking if surface_proxy can cast to wl_proxy:",
			ffi.cast("struct wl_proxy*", self.surface_proxy)
		)
		print("  Checking surface_proxy interface:")
		local iface = ffi.C.wl_proxy_get_interface(ffi.cast("struct wl_proxy*", self.surface_proxy))

		if iface ~= nil then
			print("    interface name:", ffi.string(iface.name))
			print("    interface version:", iface.version)
		else
			print("    ERROR: interface is NULL!")
		end

		print(
			"  Checking surface_proxy version:",
			ffi.C.wl_proxy_get_version(ffi.cast("struct wl_proxy*", self.surface_proxy))
		)
		
		-- self.xdg_surface = self.xdg_wm_base:get_xdg_surface(self.surface_proxy)
		-- self.xdg_surface = ffi.cast("struct xdg_surface*", self.xdg_surface)
		
		self.xdg_surface = self.xdg_wm_base:get_xdg_surface(self.surface_proxy)
		self.xdg_surface = ffi.cast("struct xdg_surface*", self.xdg_surface)
		print("xdg_surface created:", self.xdg_surface)

		self:setup_xdg_surface_listener()
		-- Create toplevel
		self.xdg_toplevel = self.xdg_surface:get_toplevel()
		self.xdg_toplevel = ffi.cast("struct xdg_toplevel*", self.xdg_toplevel)
		self:setup_xdg_toplevel_listener()

		-- Set title if provided
		if self.Title then self.xdg_toplevel:set_title(self.Title) end

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
				enter = function(data, pointer, serial, surface, x, y) end,
				leave = function(data, pointer, serial, surface) end,
				motion = function(data, pointer, time, x, y)
					local wnd = wayland._active_windows[tonumber(ffi.cast("intptr_t", data))]

					if not wnd then return end

					wnd.mouse_x = tonumber(x)
					wnd.mouse_y = tonumber(y)
					table.insert(wnd.events, {type = "mouse_move", x = wnd.mouse_x, y = wnd.mouse_y})
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
				enter = function(data, keyboard, serial, surface, keys) end,
				leave = function(data, keyboard, serial, surface) end,
				key = function(data, keyboard, serial, time, key, state)
					local wnd = wayland._active_windows[tonumber(ffi.cast("intptr_t", data))]

					if not wnd then return end

					local keycode = tonumber(key) + 8
					table.insert(wnd.events, {type = state == 1 and "key_press" or "key_release", key = keycode})
				end,
				modifiers = function(data, keyboard, serial, depressed, latched, locked, group)
					local wnd = wayland._active_windows[tonumber(ffi.cast("intptr_t", data))]

					if wnd and wnd.xkb_state then
						wayland.xkb.xkb_state_update_mask(wnd.xkb_state, depressed, latched, locked, 0, 0, group)
					end
				end,
				repeat_info = function(data, keyboard, rate, delay) end,
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
			end
		end

		self:OnPostUpdate(dt)

		-- Handle trapped cursor
		if self.Cursor == "trapped" and self:IsFocused() then
			local pos = self:GetMousePosition()
			local size = self:GetSize()
			local changed = false

			if pos.x <= 1 then
				pos.x = size.x - 2
				changed = true
			end

			if pos.y <= 1 then
				pos.y = size.y - 2
				changed = true
			end

			if pos.x >= size.x - 1 then
				pos.x = 2
				changed = true
			end

			if pos.y >= size.y - 1 then
				pos.y = 2
				changed = true
			end

			if changed then
				self.last_mpos = pos
				self:SetMousePosition(pos)
			end
		end
	end

	function META:ReadEvents()
		local events = {}
		local pollfd = ffi.new("struct pollfd[1]")
		pollfd[0].fd = wayland.wl_client.wl_display_get_fd(self.display)
		pollfd[0].events = 1

		if ffi.C.poll(pollfd, 1, 0) > 0 then
			wayland.wl_client.wl_display_dispatch(self.display)
		else
			wayland.wl_client.wl_display_dispatch_pending(self.display)
		end

		wayland.wl_client.wl_display_flush(self.display)
		events = self.events
		self.events = {}
		return events
	end

	function META:OnRemove()
		if self.display then
			-- Release mouse if captured
			if self:IsMouseCaptured() then self:ReleaseMouse() end

			-- Clean up wayland resources
			if self.xdg_toplevel then self.xdg_toplevel:destroy() end

			if self.xdg_surface then self.xdg_surface:destroy() end

			if self.surface_proxy then self.surface_proxy:destroy() end

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

		if mode == "trapped" then
			self:CaptureMouse()
		elseif mode == "hidden" then
			-- Wayland cursor hiding
			-- Would need to set null cursor surface
			error("nyi: hidden cursor not implemented in wayland bindings", 2)
		else
			-- Release mouse capture for normal cursors
			if self:IsMouseCaptured() then self:ReleaseMouse() end

			-- Set cursor type
			if mode ~= "arrow" then
				-- Would need to load cursor theme and set cursor
				error("nyi: cursor type '" .. mode .. "' not implemented in wayland bindings", 2)
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
		print("GetSurfaceHandle called:")
		print("  surface:", self.surface)
		print("  display:", self.display)
		print("  surface is nil?", self.surface == nil)
		print("  display is nil?", self.display == nil)
		return self.surface, self.display
	end

	function META:IsFocused()
		-- Assume focused if window is visible/configured
		return self.configured
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
		-- Wayland doesn't support true mouse capture like X11/Windows
		-- We can hide cursor and use relative motion events
		self.mouse_captured = true
	end

	function META:ReleaseMouse()
		self.mouse_captured = false
	end

	function META:IsMouseCaptured()
		return self.mouse_captured
	end
end
