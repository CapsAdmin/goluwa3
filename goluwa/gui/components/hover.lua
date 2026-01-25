local gui = require("gui.gui")
local window = require("window")
return function(META)
	function META:IsHoveredExclusively(mouse_pos)
		mouse_pos = mouse_pos or window.GetMousePosition()
		return gui.GetHoveredObject(mouse_pos) == self
	end

	function META:IsHovered(mouse_pos)
		mouse_pos = mouse_pos or window.GetMousePosition()
		local local_pos = self:GlobalToLocal(mouse_pos)

		if self.Resizable then
			local offset = self.ResizeBorder
			return local_pos.x >= -offset.x and
				local_pos.y >= -offset.y and
				local_pos.x <= self.Size.x + offset.w and
				local_pos.y <= self.Size.y + offset.h
		end

		return local_pos.x >= 0 and
			local_pos.y >= 0 and
			local_pos.x <= self.Size.x and
			local_pos.y <= self.Size.y
	end
end
