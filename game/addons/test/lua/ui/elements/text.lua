local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local Rect = require("structs.rect")
local Color = require("structs.color")
local Ang3 = require("structs.ang3")
local fonts = require("render2d.fonts")
local Panel = require("ecs.panel")
local theme = require("ui.theme")
return function(props)
	return Panel.New({
		{
		Name = "text",
		text = {
			Font = theme.GetFont(props.FontName or "body", props.Size or "M"),
			Color = theme.GetColor("text_foreground"),
		},
		layout = {
			FitWidth = not props.Wrap,
			FitHeight = true,
		},
		transform = true,
		gui_element = true,
		mouse_input = true,
		animation = true,
	},
		props,
	})
end
