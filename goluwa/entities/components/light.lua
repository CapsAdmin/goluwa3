local objects = import("goluwa/objects/objects.lua")
local Color = import("goluwa/structs/color.lua")
local Light = objects.CreateTemplate("light")
Light.instances = {}

Light:StartStorable()
Light:GetSet("Color", Color(255, 255, 255))
Light:GetSet("Intensity", 0, {validate = "number"})
Light:GetSet("OcclusionMap", true)
Light:EndStorable()

-- all light components share this list so the render passes can iterate the
-- whole light set in a single pass
function Light:OnCreate()
	list.insert(Light.instances, self)
end

function Light:OnRemove()
	local instances = Light.instances

	for i, other in ipairs(instances) do
		if other == self then
			list.remove(instances, i)
			break
		end
	end
end

function Light.GetInstances()
	return Light.instances
end

return Light:Register()
