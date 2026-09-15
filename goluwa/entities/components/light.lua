local objects = import("goluwa/objects/objects.lua")
local Light = objects.CreateTemplate("light")
import.loaded["goluwa/entities/components/light.lua"] = Light
local Color = import("goluwa/structs/color.lua")
Light:StartStorable()
Light:GetSet("LightType", "directional", {
	enums = {"sun", "point", "directional", "spot"},
})
Light:GetSet("Color", Color(255, 255, 255))
Light:GetSet("Intensity", 0, {validate = "number"})
Light:GetSet("Range", 20, {validate = "number"})
Light:GetSet("InnerCone", 10, {validate = "number"})
Light:GetSet("OuterCone", 20, {validate = "number"})
Light:GetSet("OcclusionMap", true)
Light:EndStorable()

function Light:SetLightType(light_type)
	self.LightType = light_type

	if light_type == "sun" then self:SetName("sun") end
end

return Light:Register()
