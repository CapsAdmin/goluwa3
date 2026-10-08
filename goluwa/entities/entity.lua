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
		valid_components.network = import("goluwa/entities/components/network.lua")
		valid_components.model = import("goluwa/entities/components/model.lua")
		valid_components.light_sun = import("goluwa/entities/components/light_sun.lua")
		valid_components.light_directional = import("goluwa/entities/components/light_directional.lua")
		valid_components.light_point = import("goluwa/entities/components/light_point.lua")
		valid_components.light_spot = import("goluwa/entities/components/light_spot.lua")
		valid_components.water_volume = import("goluwa/entities/components/water_volume.lua")

		if RENDER_3D then
			valid_components.visual = import("goluwa/entities/components/visual.lua")
			valid_components.visual_primitive = import("goluwa/entities/components/visual_primitive.lua")
			valid_components.animator = import("goluwa/entities/components/animator.lua")
			valid_components.flex = import("goluwa/entities/components/flex.lua")
			valid_components.bone_pose = import("goluwa/entities/components/bone_pose.lua")
			valid_components.shadow_map_sun = import("goluwa/entities/components/shadow_map_sun.lua")
			valid_components.shadow_map_directional = import("goluwa/entities/components/shadow_map_directional.lua")
			valid_components.shadow_map_point = import("goluwa/entities/components/shadow_map_point.lua")
			valid_components.visibility_group = import("goluwa/entities/components/visibility_group.lua")
			valid_components.source_light = import("goluwa/entities/components/source_light.lua")
			valid_components.atmosphere_controller = import("goluwa/entities/components/atmosphere_controller.lua")
		end

		valid_components.bsp_world = import("goluwa/entities/components/bsp_world.lua")
		valid_components.cry_level = import("goluwa/entities/components/cry_level.lua")
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
