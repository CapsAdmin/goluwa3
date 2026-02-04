local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local Rect = require("structs.rect")
local Color = require("structs.color")
local Ang3 = require("structs.ang3")
local fonts = require("render2d.fonts")
local Text = require("ecs.entities.2d.text")
local theme = runfile("lua/ui/theme.lua")
return function(props)
	return Text(
		table.merge(
			{
				Font = theme.GetFont(props.Font or "body", props.Size or "M"),
				Color = theme.Colors[props.Color] or theme.Colors.Text,
			},
			props
		)
	)
end
