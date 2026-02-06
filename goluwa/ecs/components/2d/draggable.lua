local prototype = require("prototype")
local event = require("event")
local window = require("window")
local input = require("input")
local Vec2 = require("structs.vec2")
local META = prototype.CreateTemplate("draggable")
META:StartStorable()
META:GetSet("Draggable", true)
META:EndStorable()

function META:Initialize()
	self.drag_mouse_start = nil
	self.drag_object_start = nil
	self.drag_button = nil

	if not self.Target then self.Target = nil end

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

function META:SetTarget(target)
	self.Target = target
end

function META:GetTarget()
	return self.Target or self.Owner
end

function META:OnGlobalMouseMove(pos)
	if self:IsDragging() then
		local mouse = self.Owner.mouse_input

		if mouse then mouse:SetCursor("sizeall") end

		return true
	end
end

function META:StartDragging(button)
	local target = self:GetTarget()
	local transform = target.transform

	if not transform then return false end

	local mouse_pos = self.Owner.mouse_input:GetGlobalMousePosition()
	self.drag_mouse_start = mouse_pos:Copy()
	self.drag_object_start = transform:GetPosition():Copy()
	self.drag_button = button
	self:AddEvent("Update", {priority = 100})

	if self.Owner.OnDragStarted then self.Owner:OnDragStarted(button) end

	return true
end

function META:StopDragging()
	if self.Owner.OnDragStopped then self.Owner:OnDragStopped(self.drag_button) end

	self.drag_mouse_start = nil
	self.drag_object_start = nil
	self.drag_button = nil
	self:RemoveEvent("Update")
end

function META:IsDragging()
	return self.drag_mouse_start ~= nil
end

function META:OnUpdate()
	if self.drag_button ~= nil and not input.IsMouseDown(self.drag_button) then
		self:StopDragging()
		return
	end

	local target = self:GetTarget()
	local transform = target.transform

	if not transform then
		self:StopDragging()
		return
	end

	local pos = self.Owner.mouse_input:GetGlobalMousePosition()
	local delta = pos - self.drag_mouse_start

	if self.Owner.OnDrag then if self.Owner:OnDrag(delta, pos) then return end end

	local new_pos = self.drag_object_start + delta
	transform:SetPosition(new_pos)
end

function META:OnGlobalMouseInput(button, press, pos)
	if not self:GetDraggable() then return end

	local gui = self.Owner.gui_element

	if gui and not gui:GetVisible() then return end

	if button == "button_1" and press then
		local gui = self.Owner.gui_element

		if gui and gui:IsHovered(pos) then
			do -- Only start dragging if not already resizing
				local target = self:GetTarget()
				local resizable = target.resizable

				if resizable and resizable:IsResizing() then return end
			end

			self:StartDragging(button)
			return true
		end
	end
end

function META:OnRemove()
	if self:IsDragging() then self:StopDragging() end

	if self.remove_global_input then self.remove_global_input() end

	if self.remove_global_move then self.remove_global_move() end
end

return META:Register()
