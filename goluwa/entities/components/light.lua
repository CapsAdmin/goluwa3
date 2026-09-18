local objects = import("goluwa/objects/objects.lua")
local Color = import("goluwa/structs/color.lua")
local Light = objects.CreateTemplate("light")
Light.instances = {}

Light:StartStorable()
Light:GetSet("Color", Color(1, 1, 1, 1))
Light:GetSet("Lumen", 0, {validate = "number"})
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

local CUTOFF_ILLUMINANCE = 0.05

function Light:GetPhotometricAmount()
	return self.Lumen
end

function Light:SetPhotometricAmount(amount)
	return self:SetLumen(amount)
end

function Light:GetEmissionSolidAngle()
	return 4 * math.pi
end

function Light:GetInverseEmissionSolidAngle()
	return 1 / self:GetEmissionSolidAngle()
end

function Light:GetEffectiveRange()
	if self.Range > 0 then return self.Range end

	if self.Lumen <= 0 then return 0 end

	return math.sqrt(self.Lumen / (self:GetEmissionSolidAngle() * CUTOFF_ILLUMINANCE))
end

return Light:Register()
