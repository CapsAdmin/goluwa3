local lsx = require("ecs.lsx_ecs")
local Color = require("structs.color")
local Vec2 = require("structs.vec2")

return function(props)
	return lsx:Panel({
		Name = "MenuSpacer",
		Size = props.Vertical and Vec2(1, props.Size or 10) or Vec2(props.Size or 10, 1),
		Color = Color(0, 0, 0, 0),
		Layout = props.Layout,
		Stackable = true,
	})
end
