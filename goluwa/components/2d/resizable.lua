local prototype = require("prototype")
local window = require("window")
local transform_comp = require("components.2d.transform").Component
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local input = require("input")
local META = prototype.CreateTemplate("resizable_2d")
META.ComponentName = "resizable_2d"
META.Require = {transform_comp}
META:StartStorable()
META:GetSet("ResizeBorder", Rect(8, 8, 8, 8))
META:GetSet("Resizable", true)
META:GetSet("MinimumSize", Vec2(10, 10))
META:EndStorable()

function META:Initialize()
	self.resize_start_pos = nil
	self.resize_location = nil
	self.resize_prev_mouse_pos = nil
	self.resize_prev_pos = nil
	self.resize_prev_size = nil
	self.resize_button = nil
end

function META:GetMousePosition()
	local mouse_pos = window.GetMousePosition()
	return self.Entity.transform_2d:GlobalToLocal(mouse_pos)
end

function META:GetMouseLocation(pos)
	pos = pos or self:GetMousePosition()
	local offset = self.ResizeBorder
	local transform = self.Entity.transform_2d
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

	if loc then
		local transform = self.Entity.transform_2d
		self.resize_start_pos = local_pos:Copy()
		self.resize_location = loc
		self.resize_prev_mouse_pos = window.GetMousePosition():Copy()
		self.resize_prev_pos = transform:GetPosition():Copy()
		self.resize_prev_size = transform:GetSize():Copy()
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

function META:UpdateResizing(pos)
	if self.resize_button ~= nil and not input.IsMouseDown(self.resize_button) then
		self:StopResizing()
		return
	end

	local transform = self.Entity.transform_2d
	local diff_world = pos - self.resize_prev_mouse_pos
	local loc = self.resize_location
	local prev_size = self.resize_prev_size:Copy()
	local prev_pos = self.resize_prev_pos:Copy()
	local min_size = self:GetMinimumSize()

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

	local parent = self.Entity:GetParent()

	if parent and parent:IsValid() and parent.transform_2d then
		local p_transform = parent.transform_2d
		local p_size = p_transform:GetSize()
		prev_pos.x = math.max(prev_pos.x, 0)
		prev_pos.y = math.max(prev_pos.y, 0)
		prev_size.x = math.min(prev_size.x, p_size.x - prev_pos.x)
		prev_size.y = math.min(prev_size.y, p_size.y - prev_pos.y)
	end

	transform:SetPosition(prev_pos)
	transform:SetSize(prev_size)
end

local resizable = {}
resizable.Component = META:Register()
return resizable
