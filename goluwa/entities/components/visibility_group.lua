local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local VisibilityGroup = objects.CreateTemplate("visibility_group")
VisibilityGroup.has_boxes = false
VisibilityGroup:StartStorable()
VisibilityGroup:GetSet("Boxes", nil, {Hidden = true})
VisibilityGroup:EndStorable()
local KEEP_MARGIN = 0.15

local function apply(self, shown)
	self.shown = shown
	self.applied_list = self.Owner:GetChildrenList()

	for _, child in ipairs(self.applied_list) do
		local visual = child.visual

		if visual then visual:SetVisible(shown) end

		local light = child.light_point or child.light_spot

		if light then light:SetVisible(shown) end

		local water_volume = child.water_volume

		if water_volume then water_volume:SetVisible(shown) end
	end
end

function VisibilityGroup:SetBoxes(boxes)
	self.Boxes = boxes
	self.bounds = nil

	if not boxes or not boxes[1] then return end

	local min_x, min_y, min_z = math.huge, math.huge, math.huge
	local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

	for i = 1, #boxes, 6 do
		min_x, min_y, min_z = math.min(min_x, boxes[i]),
		math.min(min_y, boxes[i + 1]),
		math.min(min_z, boxes[i + 2])
		max_x, max_y, max_z = math.max(max_x, boxes[i + 3]),
		math.max(max_y, boxes[i + 4]),
		math.max(max_z, boxes[i + 5])
	end

	self.bounds = {min_x, min_y, min_z, max_x, max_y, max_z}
	VisibilityGroup.has_boxes = true
end

local function get_offset(group)
	local root = group.Owner:GetParent()

	if root:IsValid() and root.transform then
		return root.transform:GetWorldPosition()
	end
end

local function inside(group, position, margin)
	local x, y, z = position.x, position.y, position.z
	local bounds = group.bounds

	if not bounds then return false end

	local offset = get_offset(group)

	if offset then x, y, z = x - offset.x, y - offset.y, z - offset.z end

	if
		x < bounds[1] - margin or
		y < bounds[2] - margin or
		z < bounds[3] - margin or
		x > bounds[4] + margin or
		y > bounds[5] + margin or
		z > bounds[6] + margin
	then
		return false
	end

	local boxes = group.Boxes

	for i = 1, #boxes, 6 do
		if
			x >= boxes[i] - margin and
			y >= boxes[i + 1] - margin and
			z >= boxes[i + 2] - margin and
			x <= boxes[i + 3] + margin and
			y <= boxes[i + 4] + margin and
			z <= boxes[i + 5] + margin
		then
			return true
		end
	end

	return false
end

function VisibilityGroup.Locate(position, found)
	local count = 0

	for _, group in ipairs(VisibilityGroup.Instances) do
		if inside(group, position, 0) then
			found[group] = true
			count = count + 1
		end
	end

	return count
end

VisibilityGroup.active = nil

local function set_shown(target)
	local changed = false

	for _, group in ipairs(VisibilityGroup.Instances) do
		local shown = target == nil or target[group] == true

		if group.shown ~= shown then
			apply(group, shown)
			changed = true
		end
	end

	if changed then ddgi.ResetHistory() end
end

function VisibilityGroup.GetActive()
	return VisibilityGroup.active
end

function VisibilityGroup.ShowAll()
	if VisibilityGroup.active == nil then return end

	VisibilityGroup.active = nil
	set_shown(nil)
end

function VisibilityGroup:OnCreate()
	self.shown = true
end

function VisibilityGroup:OnRemove()
	self.shown = true

	if VisibilityGroup.active and VisibilityGroup.active[self] then
		VisibilityGroup.ShowAll()
	end
end

function VisibilityGroup:OnFirstCreated()
	local found, current = {}, {}

	event.AddListener("Update", "visibility_groups", function()
		if VisibilityGroup.has_boxes then
			local position = render3d.GetCamera():GetPosition()
			table.clear(found)

			if VisibilityGroup.Locate(position, found) > 0 then
				table.clear(current)

				for group in pairs(found) do
					current[group] = true
				end

				VisibilityGroup.active = current
				set_shown(current)
			else
				local keep = false

				for group in pairs(VisibilityGroup.active or {}) do
					if inside(group, position, KEEP_MARGIN) then
						keep = true

						break
					end
				end

				if not keep then VisibilityGroup.ShowAll() end
			end
		end

		for _, group in ipairs(VisibilityGroup.Instances) do
			if not group.shown and group.Owner:GetChildrenList() ~= group.applied_list then
				apply(group, false)
			end
		end
	end)
end

return VisibilityGroup:Register()
