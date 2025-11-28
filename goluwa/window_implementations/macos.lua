local ffi = require("ffi")
local cocoa = require("bindings.cocoa")
local objc = require("bindings.objc")
local Vec2 = require("structs.vec2")
local system = require("system")
local event = require("event")
return function(META)
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

		-- Add event handlers
		if not system.disable_window then
			self:AddEvent("Update")
			self:AddEvent("FrameEnd")
		end

		return true
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
		-- Read all events from cocoa
		local events = self.cocoa_window:ReadEvents()

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
				local button = button_translate[event.button] or event.button
				local pressed = event.action == "pressed"
				self:CallEvent("MouseInput", button, pressed)
			elseif event.type == "mouse_move" then
				self.last_mouse_pos.x = event.x
				self.last_mouse_pos.y = event.y
				self:SetMouseDelta(Vec2(event.delta_x, event.delta_y))
				self:CallEvent("CursorPosition", Vec2(event.x, event.y))
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

	function META:OnRemove()
		if self.cocoa_window then
			-- Release mouse if captured
			if self.cocoa_window:IsMouseCaptured() then
				self.cocoa_window:ReleaseMouse()
			end
		-- Window cleanup would go here if cocoa exposed it
		end
	end

	function META:Maximize()
		error("nyi: Maximize not implemented in cocoa bindings", 2)
	end

	function META:Minimize()
		error("nyi: Minimize not implemented in cocoa bindings", 2)
	end

	function META:Restore()
		error("nyi: Restore not implemented in cocoa bindings", 2)
	end

	function META:SetCursor(mode)
		if not self.Cursors[mode] then mode = "arrow" end

		self.Cursor = mode

		if mode == "trapped" then
			self.cocoa_window:CaptureMouse()
		elseif mode == "hidden" then
			-- Note: cocoa doesn't expose separate hidden cursor
			-- CaptureMouse also hides the cursor
			error("nyi: hidden cursor not implemented separately in cocoa bindings", 2)
		else
			-- Release mouse capture for normal cursors
			if self.cocoa_window:IsMouseCaptured() then
				self.cocoa_window:ReleaseMouse()
			end

			-- Note: cocoa doesn't expose setting different cursor types
			-- Would need NSCursor API
			if mode ~= "arrow" then
				error("nyi: cursor type '" .. mode .. "' not implemented in cocoa bindings", 2)
			end
		end
	end

	function META:GetPosition()
		if not self.cached_pos then
			-- Note: cocoa doesn't expose GetPosition
			error("nyi: GetPosition not implemented in cocoa bindings", 2)
		end

		return self.cached_pos
	end

	function META:SetPosition(pos)
		self.cached_pos = nil
		-- Note: cocoa doesn't expose SetPosition
		error("nyi: SetPosition not implemented in cocoa bindings", 2)
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
		-- Note: cocoa doesn't expose SetMousePosition directly
		-- Would need CGWarpMouseCursorPosition with proper coordinate conversion
		error("nyi: SetMousePosition not implemented in cocoa bindings", 2)
	end

	function META:GetSurfaceHandle()
		return self.cocoa_window:GetSurfaceHandle()
	end

	function META:IsFocused()
		-- Assume focused if window is visible
		-- More sophisticated focus tracking would need NSWindow key window status
		return self.cocoa_window:IsVisible()
	end

	function META:SetClipboard(text)
		error("nyi: SetClipboard not implemented in cocoa bindings", 2)
	end

	function META:GetClipboard()
		error("nyi: GetClipboard not implemented in cocoa bindings", 2)
	end

	function META:SwapInterval(interval)
		error("nyi: SwapInterval not implemented in cocoa bindings", 2)
	end
end
