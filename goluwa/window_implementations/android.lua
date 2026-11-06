local android = import("goluwa/bindings/android.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
return function(META)
	local APP_CMD = android.APP_CMD
	local lib = android.lib
	local app = android.app

	function META.GetDesktopSize()
		if app.window == nil then return nil end

		return Vec2(lib.ANativeWindow_getWidth(app.window), lib.ANativeWindow_getHeight(app.window))
	end

	function META:Initialize()
		self.focused = false
		self.last_mouse_pos = Vec2(0, 0)

		while app.window == nil do
			if app.destroyRequested ~= 0 then
				error("the activity was destroyed before it got a window", 2)
			end

			android.Poll(100, self)
		end

		self.cached_size = Vec2(lib.ANativeWindow_getWidth(app.window), lib.ANativeWindow_getHeight(app.window))
		self.touch = {active = false}
		self.mouse_button_state = 0
		event.AddListener("TextInputStart", self, android.ShowSoftKeyboard)
		event.AddListener("TextInputStop", self, android.HideSoftKeyboard)
		self.initialized = true
		return true
	end

	function META:OnAndroidCommand(cmd)
		if not self.initialized then
			if cmd == APP_CMD.GAINED_FOCUS then self.focused = true end

			return
		end

		if cmd == APP_CMD.TERM_WINDOW or cmd == APP_CMD.DESTROY then
			system.ShutDown(0)
		elseif cmd == APP_CMD.GAINED_FOCUS then
			self.focused = true
			self:OnGainedFocus()
		elseif cmd == APP_CMD.LOST_FOCUS then
			self.focused = false
			self:OnLostFocus()
		end
	end

	local TAP_SLOP = 24
	local LONG_PRESS_SECONDS = 0.5
	local SCROLL_STEP = 48
	local mouse_buttons = {[1] = "button_1", [2] = "button_2", [4] = "button_3"}

	function META:MoveCursor(pos)
		self:SetMouseDelta(self:GetMouseDelta() + (pos - self.last_mouse_pos))
		self.last_mouse_pos = pos
		self:OnCursorPosition(pos)
	end

	function META:OnAndroidMouse(event, action)
		self:MoveCursor(Vec2(lib.AMotionEvent_getX(event, 0), lib.AMotionEvent_getY(event, 0)))

		if action == android.MOTION_EVENT_ACTION_SCROLL then
			self:OnMouseScroll(
				Vec2(
					lib.AMotionEvent_getAxisValue(event, android.MOTION_EVENT_AXIS_HSCROLL, 0),
					lib.AMotionEvent_getAxisValue(event, android.MOTION_EVENT_AXIS_VSCROLL, 0)
				)
			)
		end

		local state = lib.AMotionEvent_getButtonState(event)

		-- injected mouse events and some touchpads report down and up without any button bits
		if state == 0 and action == android.MOTION_EVENT_ACTION_DOWN then state = 1 end

		local changed = bit.bxor(state, self.mouse_button_state)
		self.mouse_button_state = state

		for bit_value, button in pairs(mouse_buttons) do
			if bit.band(changed, bit_value) ~= 0 then
				self:OnMouseInput(button, bit.band(state, bit_value) ~= 0)
			end
		end
	end

	function META:OnAndroidTouch(event, action)
		local touch = self.touch
		local pos = Vec2(lib.AMotionEvent_getX(event, 0), lib.AMotionEvent_getY(event, 0))

		if action == android.MOTION_EVENT_ACTION_DOWN then
			touch.active = true
			touch.start = pos
			touch.start_time = system.GetTime()
			touch.pressed = false
			touch.long_pressed = false
			touch.scrolling = false
			self:MoveCursor(pos)
		elseif action == android.MOTION_EVENT_ACTION_POINTER_DOWN then
			if touch.pressed then self:OnMouseInput("button_1", false) end

			touch.pressed = false
			touch.scrolling = true
			touch.scroll_y = (pos.y + lib.AMotionEvent_getY(event, 1)) / 2
		elseif action == android.MOTION_EVENT_ACTION_MOVE then
			if touch.scrolling then
				if lib.AMotionEvent_getPointerCount(event) < 2 then return end

				local y = (pos.y + lib.AMotionEvent_getY(event, 1)) / 2

				while math.abs(y - touch.scroll_y) >= SCROLL_STEP do
					local direction = y > touch.scroll_y and 1 or -1
					touch.scroll_y = touch.scroll_y + direction * SCROLL_STEP
					self:OnMouseScroll(Vec2(0, direction))
				end
			elseif touch.pressed then
				self:MoveCursor(pos)
			elseif not touch.long_pressed and (pos - touch.start):GetLength() > TAP_SLOP then
				touch.pressed = true
				self:OnMouseInput("button_1", true)
				self:MoveCursor(pos)
			end
		elseif
			action == android.MOTION_EVENT_ACTION_UP or
			action == android.MOTION_EVENT_ACTION_CANCEL
		then
			if touch.pressed then
				self:OnMouseInput("button_1", false)
			elseif
				action == android.MOTION_EVENT_ACTION_UP and
				not touch.scrolling and
				not touch.long_pressed
			then
				self:OnMouseInput("button_1", true)
				self:OnMouseInput("button_1", false)
			end

			touch.active = false
		end
	end

	function META:UpdateLongPress()
		local touch = self.touch

		if
			touch.active and
			not touch.pressed and
			not touch.scrolling and
			not touch.long_pressed and
			system.GetTime() - touch.start_time >= LONG_PRESS_SECONDS
		then
			touch.long_pressed = true
			self:OnMouseInput("button_2", true)
			self:OnMouseInput("button_2", false)
		end
	end

	function META:OnAndroidKey(event)
		local keycode = lib.AKeyEvent_getKeyCode(event)
		local key = android.KEYCODES[keycode]

		if not key then return false end

		local action = lib.AKeyEvent_getAction(event)

		if action == android.KEY_EVENT_ACTION_DOWN then
			if lib.AKeyEvent_getRepeatCount(event) > 0 then
				self:OnKeyInputRepeat(key)
			else
				self:OnKeyInput(key, true)
			end

			local characters = android.KEY_CHARACTERS[keycode]
			local meta = lib.AKeyEvent_getMetaState(event)

			if
				characters and
				bit.band(meta, bit.bor(android.META_CTRL_ON, android.META_ALT_ON)) == 0
			then
				local shift = bit.band(meta, android.META_SHIFT_ON) ~= 0

				if
					keycode >= 29 and
					keycode <= 54 and
					bit.band(meta, android.META_CAPS_LOCK_ON) ~= 0
				then
					shift = not shift
				end

				self:OnCharInput(characters[shift and 2 or 1])
			end
		elseif action == android.KEY_EVENT_ACTION_UP then
			self:OnKeyInput(key, false)
		end

		return true
	end

	function META:OnAndroidInput(event)
		if not self.initialized then return false end

		local event_type = lib.AInputEvent_getType(event)

		if event_type == android.INPUT_EVENT_TYPE_MOTION then
			local action = bit.band(lib.AMotionEvent_getAction(event), android.MOTION_EVENT_ACTION_MASK)

			if bit.band(lib.AInputEvent_getSource(event), android.INPUT_SOURCE_MOUSE_BITS) ~= 0 then
				self:OnAndroidMouse(event, action)
			else
				self:OnAndroidTouch(event, action)
			end

			return true
		elseif event_type == android.INPUT_EVENT_TYPE_KEY then
			return self:OnAndroidKey(event)
		end

		return false
	end

	function META:OnPreUpdate(dt)
		self:SetMouseDelta(Vec2(0, 0))
		android.Poll(0, self)
		self:UpdateLongPress()
		local width = lib.ANativeWindow_getWidth(app.window)
		local height = lib.ANativeWindow_getHeight(app.window)

		if width ~= self.cached_size.x or height ~= self.cached_size.y then
			self.cached_size = Vec2(width, height)
			self:OnSizeChanged(self.cached_size:Copy())
			self:OnFramebufferResized(self.cached_size:Copy())
		end
	end

	function META:Maximize() end

	function META:Minimize() end

	function META:Restore() end

	function META:ToggleFullscreen() end

	function META:CaptureMouse() end

	function META:ReleaseMouse() end

	function META:IsMouseCaptured()
		return false
	end

	function META:SetCursor(mode)
		self.Cursor = mode
	end

	function META:GetPosition()
		return Vec2(0, 0)
	end

	function META:GetSize()
		return self.cached_size
	end

	function META:SetSize(size) end

	function META:GetFramebufferSize()
		return self.cached_size
	end

	function META:SetTitle(title) end

	function META:GetMousePosition()
		return self.last_mouse_pos
	end

	function META:SetMousePosition(pos) end

	function META:ShouldWarpMouseWhenCaptured()
		return false
	end

	function META:GetSurfaceHandle()
		return app.window
	end

	function META:IsFocused()
		return self.focused
	end
end
