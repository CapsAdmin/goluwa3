local Entity = import("goluwa/ecs/base.lua")("entity", "ecs.components.3d.", function()
	return {
		transform = import("goluwa/ecs/components/3d/transform.lua"),
		light = import("goluwa/ecs/components/3d/light.lua"),
		visual = import("goluwa/ecs/components/3d/visual.lua"),
		visual_primitive = import("goluwa/ecs/components/3d/visual_primitive.lua"),
	}
end)
Entity.World = Entity.New()
return Entity
