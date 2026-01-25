local window = require("window")
local gui = require("gui.gui")
return function(META)
	META:StartStorable()
	META:GetSet("IgnoreMouseInput", false)
	META:GetSet("FocusOnClick", false)
	META:GetSet("BringToFrontOnClick", false)
	META:GetSet("RedirectFocus", NULL)
	META:GetSet("Cursor", "arrow")
	META:GetSet("DragEnabled", false)
	META:EndStorable()

	function META:GetMousePosition()
		local mouse_pos = window.GetMousePosition()
		return self:GlobalToLocal(mouse_pos)
	end

	function META:MouseInput(button, press, pos)
		if self.IgnoreMouseInput then return end

		if press then
			if self.FocusOnClick then self:RequestFocus() end

			if self.BringToFrontOnClick then self:BringToFront() end

			if button == "button_1" then
				local hovered = gui.GetHoveredObject(pos)

				if hovered and hovered:GetDragEnabled() then
					gui.DraggingObject = hovered
					gui.DragMouseStart = pos:Copy()
					gui.DragObjectStart = hovered:GetPosition():Copy()
				end

				if not self.Resizable or not self:StartResizing(nil, button) then
					if self.Draggable then self:StartDragging(button) end
				end
			end
		else
			gui.DraggingObject = nil
		end

		-- todo, trigger button release events outside of the panel
		self.button_states = self.button_states or {}
		self.button_states[button] = {press = press, pos = pos}
		self:OnMouseInput(button, press, pos)
		self:CallLocalListeners("MouseInput", button, press, pos)
	end

	function META:IsMouseButtonDown(button)
		self.button_states = self.button_states or {}
		local state = self.button_states[button]
		return state and state.press
	end

	function META:OnMouseInput(button, press, pos)
		if self.ScrollEnabled then
			if button == "mwheel_up" then
				local s = self:GetScroll() + Vec2(0, -20)
				self:SetScroll(s)
				return true
			elseif button == "mwheel_down" then
				local s = self:GetScroll() + Vec2(0, 20)
				s.y = math.min(s.y, 0)
				self:SetScroll(s)
				return true
			end
		end
	end
end
