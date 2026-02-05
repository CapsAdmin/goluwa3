local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local Rect = require("structs.rect")
local Color = require("structs.color")
local Ang3 = require("structs.ang3")
local fonts = require("render2d.fonts")
local Panel = require("ecs.panel")
local theme = runfile("lua/ui/theme.lua")
return function(props)
	return Panel.NewText(
		table.merge(
			{
				Font = theme.GetFont(props.Font or "body", props.Size or "M"),
				Color = theme.GetColor("text_foreground"),
			},
			props
		)
	)
end
