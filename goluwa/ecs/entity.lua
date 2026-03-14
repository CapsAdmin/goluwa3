local Entity = import("goluwa/ecs/base.lua")("entity", "ecs.components.3d.", function()
	return {
		transform = import("goluwa/ecs/components/3d/transform.lua"),
		kinematic_controller = import("goluwa/ecs/components/3d/kinematic_controller.lua"),
		light = import("goluwa/ecs/components/3d/light.lua"),
		model = import("goluwa/ecs/components/3d/model.lua"),
		rigid_body = import("goluwa/ecs/components/3d/rigid_body.lua"),
	}
end)
Entity.World = Entity.New()
return Entity