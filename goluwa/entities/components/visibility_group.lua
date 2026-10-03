local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local VisibilityGroup = objects.CreateTemplate("visibility_group")
VisibilityGroup.locator = nil
VisibilityGroup.active = nil

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

function VisibilityGroup.SetLocator(locator)
	VisibilityGroup.locator = locator
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
		local locator = VisibilityGroup.locator

		if locator then
			local group = locator(render3d.GetCamera():GetPosition())

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
