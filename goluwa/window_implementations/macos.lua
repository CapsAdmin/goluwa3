local ffi = require("ffi")
local cocoa = import("goluwa/bindings/cocoa.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
return function(META)
	local base_on_remove = META.OnRemove or META.OnRemoved

	local function normalize_cursor_mode(mode)
		if mode == "trapped" then return "hidden" end

		return mode
	end

	-- Button translation from cocoa to window system
	local button_translate = {
		left = "button_1",
		right = "button_2",
		middle = "button_3",
	}

	function META:Initialize()
		-- Create the cocoa window wrapper
		self.cocoa_window = cocoa.window()
		self.cocoa_window:Initialize()

		-- Set initial title and size if provided
		if self.Title then self.cocoa_window:SetTitle(self.Title) end

		if self.Size and (self.Size.x > 0 and self.Size.y > 0) then

		-- Note: Cocoa doesn't expose SetSize in the current implementation
		-- Size would need to be set via NSWindow's setFrame method
		end

		-- Open the window
		self.cocoa_window:OpenWindow()
		-- Cache values
		self.cached_pos = nil
		self.cached_size = nil
		self.cached_fb_size = nil
		self.last_mouse_pos = Vec2(0, 0)
		self.focused = self.cocoa_window:IsFocused()
		self.mouse_inside = false
		self.is_minimized = self.cocoa_window:IsMinimized()
		self.is_maximized = self.cocoa_window:IsMaximized()
		return true
	end

	function META:OnUpdate(dt)
		self:SetMouseDelta(Vec2(0, 0))
		-- Read all events from cocoa
		local events = self.cocoa_window:ReadEvents()

		for _, event in ipairs(events) do
			if event.type == "key_press" then
				if event.is_repeat then
					self:OnKeyInputRepeat(event.key, true)
				else
					self:OnKeyInput(event.key, true)
				end

				-- Fire character input if available
				if event.char and event.char ~= "" then self:OnCharInput(event.char) end
			elseif event.type == "key_release" then
				self:OnKeyInput(event.key, false)
			elseif event.type == "mouse_button" then
				local button = button_translate[event.button] or event.button
				local pressed = event.action == "pressed"
				self:OnMouseInput(button, pressed)
			elseif event.type == "mouse_move" then
				self.last_mouse_pos.x = event.x
				self.last_mouse_pos.y = event.y
				self:SetMouseDelta(Vec2(event.delta_x, event.delta_y))
				self:OnCursorPosition(Vec2(event.x, event.y))
			elseif event.type == "mouse_scroll" then
				self:OnMouseScroll(Vec2(event.delta_x, event.delta_y))
			elseif event.type == "drop" then
				self:OnDrop(event.paths)
			elseif event.type == "window_close" then
				self:OnClose()
			elseif event.type == "window_resize" then
				self.cached_size = nil
				self.cached_fb_size = nil
				self:OnSizeChanged(Vec2(event.width, event.height))
				self:OnFramebufferResized(Vec2(event.width, event.height))
			end
		end

		local focused = self.cocoa_window:IsFocused()

		if focused ~= self.focused then
			self.focused = focused

			if focused then self:OnGainedFocus() else self:OnLostFocus() end
		end

		local pos = self.cocoa_window:GetPosition()

		if not self.cached_pos or self.cached_pos.x ~= pos.x or self.cached_pos.y ~= pos.y then
			self.cached_pos = pos
			self:OnPositionChanged(pos:Copy())
		end

		local minimized = self.cocoa_window:IsMinimized()

		if minimized ~= self.is_minimized then
			self.is_minimized = minimized

			if minimized then self:OnMinimize() end
		end

		local maximized = self.cocoa_window:IsMaximized()

		if maximized ~= self.is_maximized then
			self.is_maximized = maximized

			if maximized then self:OnMaximize() end
		end

		local mouse_pos = self.cocoa_window:GetMousePosition()
		local size = self:GetSize()
		local mouse_inside = mouse_pos.x >= 0 and
			mouse_pos.y >= 0 and
			mouse_pos.x <= size.x and
			mouse_pos.y <= size.y

		if mouse_inside ~= self.mouse_inside then
			self.mouse_inside = mouse_inside

			if mouse_inside then
				self:OnCursorEnter()
			else
				self:OnCursorLeave()
			end
		end
	end

	function META:OnRemove()
		if self.cocoa_window then
			-- Release mouse if captured
			if self.cocoa_window:IsMouseCaptured() then
				self.cocoa_window:ReleaseMouse()
			end

			self.cocoa_window:Destroy()

			-- Window cleanup would go here if cocoa exposed it
			if base_on_remove then base_on_remove(self) end
		end
	end

	function META:Maximize()
		self.cocoa_window:Maximize()
	end

	function META:Minimize()
		self.cocoa_window:Minimize()
	end

	function META:Restore()
		self.cocoa_window:Restore()
	end

	function META:CaptureMouse()
		self.cocoa_window:CaptureMouse()
	end

	function META:ReleaseMouse()
		self.cocoa_window:ReleaseMouse()
	end

	function META:IsMouseCaptured()
		return self.cocoa_window:IsMouseCaptured()
	end

	function META:SetCursor(mode)
		if not self.Cursors[mode] then mode = "arrow" end

		mode = normalize_cursor_mode(mode)
		self.Cursor = mode
		self.cocoa_window:SetCursor(mode)
	end

	function META:GetPosition()
		if not self.cached_pos then
			self.cached_pos = self.cocoa_window:GetPosition()
		end

		return self.cached_pos
	end

	function META:GetSize()
		if not self.cached_size then
			local w, h = self.cocoa_window:GetSize()
			self.cached_size = Vec2(w, h)
		end

		return self.cached_size
	end

	function META:SetSize(size)
		self.cached_size = nil
		self.cached_fb_size = nil
		-- Note: cocoa doesn't expose SetSize
		error("nyi: SetSize not implemented in cocoa bindings", 2)
	end

	function META:GetFramebufferSize()
		if not self.cached_fb_size then
			-- On macOS, framebuffer size is same as window size for Metal
			-- unless dealing with Retina displays
			local w, h = self.cocoa_window:GetSize()
			self.cached_fb_size = Vec2(w, h)
		end

		return self.cached_fb_size
	end

	function META:SetTitle(title)
		self.cocoa_window:SetTitle(tostring(title))
	end

	function META:GetMousePosition()
		-- Return cached mouse position from move events
		return self.last_mouse_pos
	end

	function META:SetMousePosition(pos)
		local x = math.floor(tonumber(pos.x) or 0)
		local y = math.floor(tonumber(pos.y) or 0)
		self.last_mouse_pos = Vec2(x, y)
		self.cocoa_window:SetMousePosition(self.last_mouse_pos)
	end

	function META:GetSurfaceHandle()
		return self.cocoa_window:GetSurfaceHandle()
	end

	function META:IsFocused()
		return self.focused
	end
end
