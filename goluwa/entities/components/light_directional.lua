local objects = import("goluwa/objects/objects.lua")
local Light = import("goluwa/entities/components/light.lua")
local DirectionalLight = objects.CreateTemplate("light_directional")
DirectionalLight.Base = Light
DirectionalLight:StartStorable()
DirectionalLight:GetSet("Range", 20, {validate = "number"})
DirectionalLight:EndStorable()
return DirectionalLight:Register()
