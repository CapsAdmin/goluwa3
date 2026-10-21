local objects = import("goluwa/objects/objects.lua")
local Light = import("goluwa/entities/components/light.lua")
local SpotLight = objects.CreateTemplate("light_spot")
SpotLight.Base = Light
SpotLight.Network = table.merge_many(
	Light.Network,
	{
		Range = {"number", 0.5, "reliable"},
		InnerCone = {"number", 0.5, "reliable"},
		OuterCone = {"number", 0.5, "reliable"},
	}
)
SpotLight:StartStorable()
SpotLight:GetSet("Range", 0, {validate = "number"})
SpotLight:GetSet("InnerCone", 10, {validate = "number"})
SpotLight:GetSet("OuterCone", 20, {validate = "number"})
SpotLight:EndStorable()
local MIN_OUTER_CONE_DEGREES = 0.5

function SpotLight:GetEmissionSolidAngle()
	local outer = math.clamp(self.OuterCone, MIN_OUTER_CONE_DEGREES, 180)
	local cos_inner = math.cos(math.rad(math.clamp(self.InnerCone, 0, 180)))
	local cos_outer = math.min(math.cos(math.rad(outer)), cos_inner)
	return 2 * math.pi * (1 - (cos_inner + cos_outer) / 2)
end

return SpotLight:Register()
