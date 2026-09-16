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
			valid_components.light_sun = import("goluwa/entities/components/light_sun.lua")
			valid_components.light_directional = import("goluwa/entities/components/light_directional.lua")
			valid_components.light_point = import("goluwa/entities/components/light_point.lua")
			valid_components.light_spot = import("goluwa/entities/components/light_spot.lua")
			valid_components.visual = import("goluwa/entities/components/visual.lua")
			valid_components.visual_primitive = import("goluwa/entities/components/visual_primitive.lua")
			valid_components.shadow_map_sun = import("goluwa/entities/components/shadow_map_sun.lua")
			valid_components.shadow_map_directional = import("goluwa/entities/components/shadow_map_directional.lua")
			valid_components.shadow_map_point = import("goluwa/entities/components/shadow_map_point.lua")
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
