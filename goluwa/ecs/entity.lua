local Entity = import("goluwa/ecs/base.lua")("entity", "ecs.components.3d.", function()
	return {
		transform = import("goluwa/ecs/components/3d/transform.lua"),
		light = import("goluwa/ecs/components/3d/light.lua"),
		model = import("goluwa/ecs/components/3d/model.lua"),
	}
end)
Entity.World = Entity.New()
return Entity