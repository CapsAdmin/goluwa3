local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Panel = require("ecs.entities.2d.panel")
local theme = runfile("lua/ui/theme.lua")
return function(props)
	return Panel(
		table.merge(
			{
				Name = "Row",
				Color = Color(0, 0, 0, 0),
				Layout = {"FillX", "SizeToChildrenHeight"},
				Flex = true,
				FlexDirection = "row",
				FlexAlignItems = "center",
				FlexGap = theme.Sizes2.M,
			},
			props
		)
	)
end
