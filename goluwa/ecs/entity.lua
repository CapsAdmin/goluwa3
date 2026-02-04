local Entity = require("ecs.base")("entity", "ecs.components.3d.", function()
	return {
		transform = require("ecs.components.3d.transform"),
		light = require("ecs.components.3d.light"),
		model = require("ecs.components.3d.model"),
	}
end)
Entity.World = Entity.New()
return Entity
