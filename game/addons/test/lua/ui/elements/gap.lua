local theme = runfile("lua/ui/theme.lua")
local Vec2 = require("structs.vec2")
local Panel = require("ecs.entities.2d.panel")
return function(props)
	props = props or {}
	return Panel(
		{
			Size = Vec2() + 1, --theme.Sizes2[props.Size or "S"],
			LayoutSize = Vec2() + 1, --theme.Sizes2[props.Size or "S"],
		}
	)
end
