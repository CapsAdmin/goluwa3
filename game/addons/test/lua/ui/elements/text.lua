local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local Rect = require("structs.rect")
local Color = require("structs.color")
local lsx = require("ecs.lsx_ecs")
local ecs = require("ecs.ecs")
local Ang3 = require("structs.ang3")
local fonts = require("render2d.fonts")
local path = fonts.GetSystemDefaultFont()
local font = fonts.CreateFont(
	{
		path = path,
		size = 17,
		shadow = {
			dir = -2,
			color = Color.FromHex("#022d58"):SetAlpha(0.75),
			blur_radius = 0.25,
			blur_passes = 1,
		},
	--color = {color = Color(0, 0, 1, 1)},
	}
)
return function(props)
	return lsx:Text(lsx:MergeProps({
		Font = props.Font or font,
	}, props))
end
