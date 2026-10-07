local objects = import("goluwa/objects/objects.lua")
local lights = import("goluwa/source_engine/lights.lua")
local META = objects.CreateTemplate("source_light")
META:StartStorable()
META:GetSet("Info", nil, {type = "table", callback = "Apply"})
META:EndStorable()

function META:Initialize()
	lights.Register(self)
end

function META:Apply()
	local info = self.Info
	local owner = self.Owner
	local light = owner.light_spot or owner.light_point

	if info and light then lights.Apply(light, info) end
end

return META:Register()
