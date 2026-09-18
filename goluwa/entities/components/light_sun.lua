local objects = import("goluwa/objects/objects.lua")
local Light = import("goluwa/entities/components/light.lua")
local Sun = objects.CreateTemplate("light_sun")
Sun.Base = Light
Sun:StartStorable()
Sun:GetSet("Lux", 0, {validate = "number"})
Sun:EndStorable()

function Sun:GetPhotometricAmount()
	return self.Lux
end

function Sun:SetPhotometricAmount(amount)
	return self:SetLux(amount)
end

function Sun:GetInverseEmissionSolidAngle()
	return 1
end

return Sun:Register()
