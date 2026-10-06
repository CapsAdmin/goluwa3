local objects = import("goluwa/objects/objects.lua")
local Light = import("goluwa/entities/components/light.lua")
local PointLight = objects.CreateTemplate("light_point")
PointLight.Base = Light
PointLight.Network = table.merge_many(Light.Network, {
	Range = {"number", 0.5, "reliable"},
})
PointLight:StartStorable()
PointLight:GetSet("Range", 0, {validate = "number"})
PointLight:EndStorable()
return PointLight:Register()
