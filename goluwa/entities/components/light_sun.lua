local objects = import("goluwa/objects/objects.lua")
local Light = import("goluwa/entities/components/light.lua")
local Sun = objects.CreateTemplate("light_sun")
Sun.Base = Light
return Sun:Register()
