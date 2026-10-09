local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local system = import("goluwa/system.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("slider")
META.CMP.transform = {}
META.CMP.layout = {}
META.CMP.visual = {}
META.CMP.mouse_input = {Cursor = "hand"}
META.CMP.clickable = {}
META.CMP.animation = {}
META:StartStorable()
META:GetSet("Mode", "horizontal", {enums = {"horizontal", "vertical", "2d"}})
META:GetSet("Value", nil)
META:GetSet("Min", nil)
META:GetSet("Max", nil)
META:EndStorable()

function META:SetValue(value, notify)
	self.Value = value
	self:SetState("value", value)

	if notify then self.OnChange(value, self) end

	return self
end

function META:SetMin(value)
	self.Min = value
	self:SetState("min", value)
	return self
end

function META:SetMax(value)
	self.Max = value
	self:SetState("max", value)
	return self
end

local function get_slider_size(active, mode)
	local thickness = active:GetSize("M")

	if mode == "2d" then return Vec2(100, 100) end

	if mode == "vertical" then return Vec2(thickness, 100) end

	return Vec2(100, thickness)
end

function META.PropDefaults(_, props)
	local is_2d = props.Mode == "2d"
	local size = theme.Dynamic(get_slider_size, props.Mode)
	return {
		Size = size,
		layout = {MinSize = size},
		Value = is_2d and Vec2(0.5, 0.5) or 0.5,
		Min = is_2d and Vec2(0, 0) or 0,
		Max = is_2d and Vec2(1, 1) or 1,
	}
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	self:SetState("mode", self.Mode)
	self:SetState("hovered", false)
	self:SetState("dragging", false)
	self:SetValue(self.Value)
	self:SetMin(self.Min)
	self:SetMax(self.Max)
end

function META.OnChange(value, slider) end

function META:set_value_from_position(local_pos)
	local size = self.transform:GetSize()
	local knob_size = theme.active:GetSize("M")
	local min = self.Min
	local max = self.Max
	local value

	if self.Mode == "2d" then
		local usable_width = size.x - knob_size
		local usable_height = size.y - knob_size

		if usable_width <= 0 or usable_height <= 0 then return end

		local nx = math.clamp((local_pos.x - knob_size / 2) / usable_width, 0, 1)
		local ny = math.clamp((local_pos.y - knob_size / 2) / usable_height, 0, 1)
		value = Vec2(min.x + nx * (max.x - min.x), min.y + ny * (max.y - min.y))
	else
		local vertical = self.Mode == "vertical"
		local usable = (vertical and size.y or size.x) - knob_size

		if usable <= 0 then return end

		local normalized = math.clamp(((vertical and local_pos.y or local_pos.x) - knob_size / 2) / usable, 0, 1)
		value = min + normalized * (max - min)
	end

	self:SetValue(value, true)
end

function META:OnMouseInput(button, press, local_pos)
	if button ~= "button_1" then return end

	if press then
		self:SetState("dragging", true)
		self:set_value_from_position(local_pos)
	end

	return true
end

function META:OnGlobalMouseInput(button, press)
	if button == "button_1" and not press and self:GetState("dragging") then
		self:SetState("dragging", false)
		return true
	end
end

function META:OnHover(hovered)
	self:SetState("hovered", hovered)
end

function META:OnDraw()
	if self:GetState("dragging") then
		self:set_value_from_position(self.transform:GlobalToLocal(system.GetWindow():GetMousePosition()))
	end

	theme.active:Draw(self)
end

return META:Register()
