local prototype = require("prototype")
local event = require("event")
local Vec2 = require("structs.vec2")
local META = prototype.CreateTemplate("draggable")
META:StartStorable()
META:GetSet("Draggable", true)
META:EndStorable()

function META:Initialize()
	self.drag_mouse_start = nil
	self.drag_object_start = nil
	self.drag_button = nil
end

function META:StartDragging(button)
	local transform = self.Owner.transform

	if not transform then return false end

	local mouse_pos = self.Owner.mouse_input:GetGlobalMousePosition()
	self.drag_mouse_start = mouse_pos:Copy()
	self.drag_object_start = transform:GetPosition():Copy()
	self.drag_button = button
	self:AddEvent("Update", {priority = 100})
	return true
end

function META:StopDragging()
	self.drag_mouse_start = nil
	self.drag_object_start = nil
	self.drag_button = nil
	self:RemoveEvent("Update")
end

function META:IsDragging()
	return self.drag_mouse_start ~= nil
end

function META:OnUpdate()
	if
		self.drag_button ~= nil and
		not self.Owner.mouse_input:IsMouseButtonDown(self.drag_button)
	then
		self:StopDragging()
		return
	end

	local transform = self.Owner.transform

	if not transform then
		self:StopDragging()
		return
	end

	local pos = self.Owner.mouse_input:GetGlobalMousePosition()
	local delta = pos - self.drag_mouse_start
	local new_pos = self.drag_object_start + delta
	transform:SetPosition(new_pos)
end

function META:OnMouseInput(button, press, pos)
	if not self:GetDraggable() then return end

	if button == "button_1" and press then
		do -- Only start dragging if not already resizing
			local resizable = self.Owner.resizable

			if resizable and resizable:IsResizing() then return end
		end

		self:StartDragging(button)
		return true
	end
end

function META:OnRemove()
	if self:IsDragging() then self:StopDragging() end
end

return META:Register()
