local ecs = require("ecs.ecs")
return function(parent)
	local ent = ecs.CreateEntity("gui_text", parent)
	ent:AddComponent(require("ecs.components.2d.gui_element"))
	ent:AddComponent(require("ecs.components.2d.text"))
	ent:AddComponent(require("ecs.components.2d.transform"))
	ent:AddComponent(require("ecs.components.2d.layout"))
	ent:AddComponent(require("ecs.components.2d.mouse_input"))
	ent:AddComponent(require("ecs.components.2d.animations"))
	return ent
end
