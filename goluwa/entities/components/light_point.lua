local objects = import("goluwa/objects/objects.lua")
local Light = import("goluwa/entities/components/light.lua")
local PointLight = objects.CreateTemplate("light_point")
PointLight.Base = Light
PointLight:StartStorable()
PointLight:GetSet("Range", 20, {validate = "number"})
PointLight:EndStorable()
return PointLight:Register()
