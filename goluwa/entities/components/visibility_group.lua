local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local VisibilityGroup = objects.CreateTemplate("visibility_group")
VisibilityGroup.active = nil
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

function VisibilityGroup.Locate(position)
	local x, y, z = position.x, position.y, position.z
	local best, best_volume

	for _, group in ipairs(VisibilityGroup.Instances) do
		local bounds = group.bounds

		if
			bounds and
			x >= bounds[1] and
			y >= bounds[2] and
			z >= bounds[3] and
			x <= bounds[4] and
			y <= bounds[5] and
			z <= bounds[6]
		then
			local boxes = group.Boxes

			for i = 1, #boxes, 6 do
				if
					x >= boxes[i] and
					y >= boxes[i + 1] and
					z >= boxes[i + 2] and
					x <= boxes[i + 3] and
					y <= boxes[i + 4] and
					z <= boxes[i + 5]
				then
					local volume = (
							boxes[i + 3] - boxes[i]
						) * (
							boxes[i + 4] - boxes[i + 1]
						) * (
							boxes[i + 5] - boxes[i + 2]
						)

					if not best_volume or volume < best_volume then
						best, best_volume = group, volume
					end
				end
			end
		end
	end

	if best then return best end

	local active = VisibilityGroup.active

	if active and active.bounds then
		local boxes = active.Boxes

		for i = 1, #boxes, 6 do
			if
				x >= boxes[i] - KEEP_MARGIN and
				y >= boxes[i + 1] - KEEP_MARGIN and
				z >= boxes[i + 2] - KEEP_MARGIN and
				x <= boxes[i + 3] + KEEP_MARGIN and
				y <= boxes[i + 4] + KEEP_MARGIN and
				z <= boxes[i + 5] + KEEP_MARGIN
			then
				return nil
			end
		end
	end

	return false
end

function VisibilityGroup.GetActive()
	return VisibilityGroup.active
end

function VisibilityGroup.SetActive(group)
	if VisibilityGroup.active == group then return end

	VisibilityGroup.active = group

	for _, other in ipairs(VisibilityGroup.Instances) do
		local shown = group == nil or other == group

		if other.shown ~= shown then apply(other, shown) end
	end

	if scene_bvh.has_built then scene_bvh.Build() end

	ddgi.ResetHistory()
end

function VisibilityGroup:OnCreate()
	self.shown = true
end

function VisibilityGroup:OnRemove()
	self.shown = true

	if VisibilityGroup.active == self then VisibilityGroup.SetActive(nil) end
end

function VisibilityGroup:OnFirstCreated()
	event.AddListener("Update", "visibility_groups", function()
		if VisibilityGroup.has_boxes then
			local group = VisibilityGroup.Locate(render3d.GetCamera():GetPosition())

			if group ~= nil then VisibilityGroup.SetActive(group or nil) end
		end

		for _, group in ipairs(VisibilityGroup.Instances) do
			if not group.shown and group.Owner:GetChildrenList() ~= group.applied_list then
				apply(group, false)
			end
		end
	end)
end

return VisibilityGroup:Register()
