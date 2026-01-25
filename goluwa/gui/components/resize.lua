local Rect = require("structs.rect")
local gui = require("gui.gui")
local input = require("input")
return function(META)
	META:GetSet("ResizeBorder", Rect(8, 8, 8, 8))
	META:GetSet("Resizable", false)

	function META:GetMouseLocation(pos) -- rename this function
		pos = pos or self:GetMousePosition()
		local offset = self.ResizeBorder
		local siz = self:GetSize()
		local is_top = pos.y > -offset.y and pos.y < offset.y
		local is_bottom = pos.y > siz.y - offset.h and pos.y < siz.y + offset.h
		local is_left = pos.x > -offset.x and pos.x < offset.x
		local is_right = pos.x > siz.x - offset.w and pos.x < siz.x + offset.w

		if is_top and is_left then return "top_left" end

		if is_top and is_right then return "top_right" end

		if is_bottom and is_left then return "bottom_left" end

		if is_bottom and is_right then return "bottom_right" end

		if is_left then return "left" end

		if is_right then return "right" end

		if is_bottom then return "bottom" end

		if is_top then return "top" end

		return "center"
	end

	function META:GetResizeLocation(pos)
		pos = pos or self:GetMousePosition()
		local loc = self:GetMouseLocation(pos)

		if loc ~= "center" then return loc end
	end

	function META:StartResizing(pos, button)
		local loc = self:GetResizeLocation(pos)

		if loc then
			self.resize_start_pos = self:GetMousePosition():Copy()
			self.resize_location = loc
			self.resize_prev_mouse_pos = gui.mouse_pos:Copy()
			self.resize_prev_pos = self:GetPosition():Copy()
			self.resize_prev_size = self:GetSize():Copy()
			self.resize_button = button
			return true
		end
	end

	function META:StopResizing()
		self.resize_start_pos = nil
	end

	function META:IsResizing()
		return self.resize_start_pos ~= nil
	end

	local location2cursor = {
		right = "horizontal_resize",
		left = "horizontal_resize",
		top = "vertical_resize",
		bottom = "vertical_resize",
		top_right = "top_right_resize",
		bottom_left = "bottom_left_resize",
		top_left = "top_left_resize",
		bottom_right = "bottom_right_resize",
	}
	local input = require("input")

	function META:CalcResizing()
		if self.Resizable then
			local loc = self:GetResizeLocation(self:GetMousePosition())

			if location2cursor[loc] then
				self:SetCursor(location2cursor[loc])
			else
				self:SetCursor()
			end
		end

		if self.resize_start_pos then
			if self.resize_button ~= nil and not input.IsMouseDown(self.resize_button) then
				self:StopResizing()
				return
			end

			local diff_world = gui.mouse_pos - self.resize_prev_mouse_pos
			local loc = self.resize_location
			local prev_size = self.resize_prev_size:Copy()
			local prev_pos = self.resize_prev_pos:Copy()

			if loc == "right" or loc == "top_right" or loc == "bottom_right" then
				prev_size.x = math.max(self.MinimumSize.x, prev_size.x + diff_world.x)
			elseif loc == "left" or loc == "top_left" or loc == "bottom_left" then
				local d_x = math.min(diff_world.x, prev_size.x - self.MinimumSize.x)
				prev_pos.x = prev_pos.x + d_x
				prev_size.x = prev_size.x - d_x
			end

			if loc == "bottom" or loc == "bottom_right" or loc == "bottom_left" then
				prev_size.y = math.max(self.MinimumSize.y, prev_size.y + diff_world.y)
			elseif loc == "top" or loc == "top_left" or loc == "top_right" then
				local d_y = math.min(diff_world.y, prev_size.y - self.MinimumSize.y)
				prev_pos.y = prev_pos.y + d_y
				prev_size.y = prev_size.y - d_y
			end

			if self:HasParent() and not self.ThreeDee then
				prev_pos.x = math.max(prev_pos.x, 0)
				prev_pos.y = math.max(prev_pos.y, 0)
				prev_size.x = math.min(prev_size.x, self.Parent.Size.x - prev_pos.x)
				prev_size.y = math.min(prev_size.y, self.Parent.Size.y - prev_pos.y)
			end

			self:SetPosition(prev_pos)
			self:SetSize(prev_size)

			if self.LayoutSize then self:SetLayoutSize(prev_size:Copy()) end
		end
	end
end
