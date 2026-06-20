local Entity = import("goluwa/entities/base.lua")("entity", "ecs.components.3d.", function()
	return {
		transform = import("goluwa/entities/components/transform.lua"),
		light = import("goluwa/entities/components/light.lua"),
		visual = import("goluwa/entities/components/visual.lua"),
		visual_primitive = import("goluwa/entities/components/visual_primitive.lua"),
	}
end)
Entity.World = Entity.New()
return Entity
