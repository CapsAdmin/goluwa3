local objects = import("goluwa/objects/objects.lua")
local input = import("goluwa/input.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = objects.CreateTemplate("snappable")
META:StartStorable()
META:GetSet("AlignThreshold", 10)
META:GetSet("AlignModifier", "control", {enums = {"control", "shift", "alt"}})
META:GetSet("ZoneMargin", 4)
META:GetSet("ZoneDragDistance", 4)
META:GetSet("Zones", nil)
META:EndStorable()
local modifier_down = {
	control = input.IsControlDown,
	shift = input.IsShiftDown,
	alt = input.IsAltDown,
}
local default_zones = {
	{Name = "left", Edge = "left", Rect = {0, 0, 0.5, 1}},
	{Name = "right", Edge = "right", Rect = {0.5, 0, 0.5, 1}},
	{Name = "maximize", Edge = "top", Rect = {0, 0, 1, 1}},
}

function META:Initialize()
	self.Owner:EnsureComponent("transform")
	self.snapped_zone = nil
	self.snapped_pos = nil
	self.snapped_size = nil
	self.snapped_container_size = nil
	self.restore_pos = nil
	self.restore_size = nil
	self.pending_zone = nil
	self.preview = nil
end

function META:GetZones()
	return self.Zones or default_zones
end

function META:GetContainer()
	return self.Owner:GetParent()
end

function META:GetZone(name)
	for _, zone in ipairs(self:GetZones()) do
		if zone.Name == name then return zone end
	end
end

function META:GetZoneRect(zone)
	local size = self:GetContainer().transform:GetSize()
	local r = zone.Rect
	return Vec2(r[1] * size.x, r[2] * size.y), Vec2(r[3] * size.x, r[4] * size.y)
end

function META:GetSnappedZone()
	return self.snapped_zone
end

function META:FindZone(local_mouse)
	local size = self:GetContainer().transform:GetSize()
	local margin = self.ZoneMargin

	for _, zone in ipairs(self:GetZones()) do
		local edge = zone.Edge

		if
			edge == "left" and
			local_mouse.x <= margin or
			edge == "right" and
			local_mouse.x >= size.x - margin or
			edge == "top" and
			local_mouse.y <= margin or
			edge == "bottom" and
			local_mouse.y >= size.y - margin
		then
			return zone
		end
	end
end

function META:Snap(name)
	local zone = self:GetZone(name)
	local transform = self.Owner.transform

	if not self.snapped_zone then
		self.restore_pos = transform:GetPosition():Copy()
		self.restore_size = transform:GetSize():Copy()
		self:AddGlobalEvent("Update", {priority = 100})
	end

	local pos, size = self:GetZoneRect(zone)
	transform:SetPosition(pos)
	transform:SetSize(size)
	self.snapped_zone = name
	self.snapped_pos = transform:GetPosition():Copy()
	self.snapped_size = transform:GetSize():Copy()
	self.snapped_container_size = self:GetContainer().transform:GetSize():Copy()
	self.Owner:CallLocalEvent("OnSnapChanged", name)
end

function META:ClearSnap()
	self.snapped_zone = nil
	self.snapped_pos = nil
	self.snapped_size = nil
	self.restore_pos = nil
	self.restore_size = nil
	self:RemoveEvent("Update")
	self.Owner:CallLocalEvent("OnSnapChanged", nil)
end

function META:Unsnap()
	if not self.snapped_zone then return end

	local transform = self.Owner.transform
	transform:SetPosition(self.restore_pos)
	transform:SetSize(self.restore_size)
	self:ClearSnap()
end

function META:OnUpdate()
	local transform = self.Owner.transform

	if
		transform:GetPosition() ~= self.snapped_pos or
		transform:GetSize() ~= self.snapped_size
	then
		self:ClearSnap()
		return
	end

	local container_size = self:GetContainer().transform:GetSize()

	if container_size ~= self.snapped_container_size then
		self:Snap(self.snapped_zone)
	end
end

function META:GetPreview()
	if not self.preview or not self.preview:IsValid() then
		self.preview = Panel.New{
			Parent = self:GetContainer(),
			IsInternal = true,
			Name = "snap_preview",
			IgnoreMouseInput = true,
			transform = true,
			visual = true,
			OnDraw = self.DrawPreview,
		}
	end

	return self.preview
end

function META.DrawPreview(preview)
	theme.active:Draw(preview)
end

function META:ShowPreview(zone)
	local preview = self:GetPreview()
	local pos, size = self:GetZoneRect(zone)
	preview.transform:SetPosition(pos)
	preview.transform:SetSize(size)
	preview.visual:SetVisible(true)
	preview:SendToBack()
end

function META:HidePreview()
	if self.preview and self.preview:IsValid() then
		self.preview.visual:SetVisible(false)
	end
end

local function nearest(best, delta)
	if math.abs(delta) < math.abs(best) then return delta end

	return best
end

function META:Align(pos)
	local owner = self.Owner
	local size = owner.transform:GetSize()
	local container = self:GetContainer()
	local container_size = container.transform:GetSize()
	local left, right = pos.x, pos.x + size.x
	local top, bottom = pos.y, pos.y + size.y
	local best_x, best_y = math.huge, math.huge
	best_x = nearest(best_x, 0 - left)
	best_x = nearest(best_x, container_size.x - right)
	best_y = nearest(best_y, 0 - top)
	best_y = nearest(best_y, container_size.y - bottom)

	for _, sibling in ipairs(container:GetChildren()) do
		if sibling ~= owner and sibling.snappable and sibling.visual:GetVisible() then
			local other_pos = sibling.transform:GetPosition()
			local other_size = sibling.transform:GetSize()
			local other_right = other_pos.x + other_size.x
			local other_bottom = other_pos.y + other_size.y
			best_x = nearest(best_x, other_pos.x - left)
			best_x = nearest(best_x, other_pos.x - right)
			best_x = nearest(best_x, other_right - left)
			best_x = nearest(best_x, other_right - right)
			best_y = nearest(best_y, other_pos.y - top)
			best_y = nearest(best_y, other_pos.y - bottom)
			best_y = nearest(best_y, other_bottom - top)
			best_y = nearest(best_y, other_bottom - bottom)
		end
	end

	local threshold = self.AlignThreshold
	return Vec2(
		math.abs(best_x) <= threshold and pos.x + best_x or pos.x,
		math.abs(best_y) <= threshold and pos.y + best_y or pos.y
	)
end

function META:HandleDrag(draggable, delta, mouse_pos)
	local transform = self.Owner.transform
	local container = self:GetContainer()
	local local_mouse = container.transform:GlobalToLocal(mouse_pos)
	local moved = delta:GetLength() > self.ZoneDragDistance

	if self.snapped_zone then
		if not moved then return true end

		local window_mouse = transform:GlobalToLocal(mouse_pos)
		local fraction_x = window_mouse.x / transform:GetSize().x
		local restore_size = self.restore_size
		self:Unsnap()
		transform:SetPosition(Vec2(local_mouse.x - fraction_x * restore_size.x, local_mouse.y - window_mouse.y))
		draggable:Rebase()
		return true
	end

	local zone = moved and self:FindZone(local_mouse)
	self.pending_zone = zone or nil

	if zone then self:ShowPreview(zone) else self:HidePreview() end

	if modifier_down[self.AlignModifier]() then
		transform:SetPosition(self:Align(draggable.drag_object_start + delta))
		return true
	end
end

function META:HandleDrop()
	local zone = self.pending_zone
	self.pending_zone = nil
	self:HidePreview()

	if zone then self:Snap(zone.Name) end
end

function META:OnRemove()
	if self.preview and self.preview:IsValid() then self.preview:Remove() end
end

return META:Register()
