local objects = import("goluwa/objects/objects.lua")
local Entity = objects.CreateTemplate("entity")
Entity.Base = import("goluwa/entities/base.lua")
local valid_components = {}

function Entity.RegisterComponent(name, meta)
	valid_components[name] = meta
end

function Entity.GetValidComponents()
	if not valid_components.transform then
		valid_components.transform = import("goluwa/entities/components/transform.lua")

		if RENDER_3D then
			valid_components.light = import("goluwa/entities/components/light.lua")
			valid_components.visual = import("goluwa/entities/components/visual.lua")
			valid_components.visual_primitive = import("goluwa/entities/components/visual_primitive.lua")
		end
	end

	return valid_components
end

function Entity:OnCreate(config)
	self.World = Entity.World
	Entity.BaseClass.OnCreate(self, config)
end

Entity:Register()
Entity.World = Entity.New()
Entity.World:SetName("3d world")
return Entity
