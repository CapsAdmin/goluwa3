local prototype = require("prototype")
local Vec2 = require("structs.vec2")
local event = require("event")
local window = require("window")
local input = require("input")
local Rect = require("structs.rect")
local META = prototype.CreateTemplate("resizable")
META:StartStorable()
META:GetSet("ResizeBorder", Rect() + 4)
META:GetSet("MinimumSize", Vec2(10, 10))
META:EndStorable()

function META:Initialize()
	self.resize_start_pos = nil
	self.resize_location = nil
	self.resize_prev_mouse_pos = nil
	self.resize_prev_pos = nil
	self.resize_prev_size = nil
	self.resize_button = nil
	self.remove_global_input = self.Owner:AddLocalListener(
		"OnGlobalMouseInput",
		function(_, button, press, pos)
			return self:OnGlobalMouseInput(button, press, pos)
		end,
		self
	)
	self.remove_global_move = self.Owner:AddLocalListener(
		"OnGlobalMouseMove",
		function(_, pos)
			return self:OnGlobalMouseMove(pos)
		end,
		self
	)
end

function META:GetMousePosition()
	return self.Owner.mouse_input:GetMousePosition()
end

function META:GetMouseLocation(pos)
	pos = pos or self:GetMousePosition()
	local offset = self.ResizeBorder
	local transform = self.Owner.transform
	local siz = transform:GetSize()
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

function META:GetResizeCursor(local_pos)
	local loc = self:GetResizeLocation(local_pos)
	return location2cursor[loc]
end

function META:StartResizing(local_pos, button)
	local loc = self:GetResizeLocation(local_pos)

	if not loc then return false end

	local transform = self.Owner.transform
	self.resize_start_pos = local_pos:Copy()
	self.resize_location = loc
	self.resize_prev_mouse_pos = self.Owner.mouse_input:GetGlobalMousePosition():Copy()
	self.resize_prev_pos = transform:GetPosition():Copy()
	self.resize_prev_size = transform:GetSize():Copy()
	self.resize_button = button
	self:AddGlobalEvent("Update", {priority = 100})
	return true
end

function META:StopResizing()
	self.resize_start_pos = nil
	self:RemoveEvent("Update")
end

function META:IsResizing()
	return self.resize_start_pos ~= nil
end

function META:OnUpdate()
	if self.resize_button ~= nil and not input.IsMouseDown(self.resize_button) then
		self:StopResizing()
		return
	end

	local pos = self.Owner.mouse_input:GetGlobalMousePosition()
	local transform = self.Owner.transform
	local diff_world = pos - self.resize_prev_mouse_pos
	local loc = self.resize_location
	local prev_size = self.resize_prev_size:Copy()
	local prev_pos = self.resize_prev_pos:Copy()
	local min_size = self:GetMinimumSize():Copy()

	if self.Owner.layout and self.Owner.layout.content_size then
		min_size.x = math.max(min_size.x, self.Owner.layout.content_size.x)
		min_size.y = math.max(min_size.y, self.Owner.layout.content_size.y)
	end

	if loc == "right" or loc == "top_right" or loc == "bottom_right" then
		prev_size.x = math.max(min_size.x, prev_size.x + diff_world.x)
	elseif loc == "left" or loc == "top_left" or loc == "bottom_left" then
		local d_x = math.min(diff_world.x, prev_size.x - min_size.x)
		prev_pos.x = prev_pos.x + d_x
		prev_size.x = prev_size.x - d_x
	end

	if loc == "bottom" or loc == "bottom_right" or loc == "bottom_left" then
		prev_size.y = math.max(min_size.y, prev_size.y + diff_world.y)
	elseif loc == "top" or loc == "top_left" or loc == "top_right" then
		local d_y = math.min(diff_world.y, prev_size.y - min_size.y)
		prev_pos.y = prev_pos.y + d_y
		prev_size.y = prev_size.y - d_y
	end

	local parent = self.Owner:GetParent()

	if
		parent and
		parent:IsValid() and
		parent.transform and
		parent:GetName() ~= "world"
	then
		local p_transform = parent.transform
		local p_size = p_transform:GetSize()
		prev_pos.x = math.max(prev_pos.x, 0)
		prev_pos.y = math.max(prev_pos.y, 0)
		prev_size.x = math.min(prev_size.x, p_size.x - prev_pos.x)
		prev_size.y = math.min(prev_size.y, p_size.y - prev_pos.y)
	end

	transform:SetPosition(prev_pos)
	transform:SetSize(prev_size)
end

function META:OnGlobalMouseInput(button, press, pos)
	local gui = self.Owner.gui_element

	if gui and not gui:GetVisible() then return end

	if button == "button_1" and press then
		local local_pos = self.Owner.transform:GlobalToLocal(pos)

		if self:StartResizing(local_pos, button) then return true end
	end
end

function META:OnGlobalMouseMove(pos)
	if self:IsResizing() then
		local cursor = location2cursor[self.resize_location]

		if cursor then
			self.Owner.mouse_input:SetCursor(cursor)
			return true
		end

		return
	end

	local gui = self.Owner.gui_element

	if gui and not gui:GetVisible() then return end

	local local_pos = self.Owner.transform:GlobalToLocal(pos)
	local cursor = self:GetResizeCursor(local_pos)

	if cursor then
		self.Owner.mouse_input:SetCursor(cursor)
		return true
	end
end

function META:OnRemove()
	if self:IsResizing() then self:StopResizing() end

	if self.remove_global_input then self.remove_global_input() end

	if self.remove_global_move then self.remove_global_move() end
end

return META:Register()
