local toolgun = import("lua/toolgun.lua")
local Color = import("goluwa/structs/color.lua")
return toolgun.ConstraintTool{
	Name = "slider",
	DisplayName = "Slider",
	Kind = "slider",
	Description = "Lets two objects only slide along the line between the two points.",
	Settings = {
		{
			Key = "Friction",
			Text = "Friction",
			Type = "number",
			Default = 0,
			Min = 0,
			Max = 10000,
			Precision = 0,
		},
		{Key = "NoCollide", Text = "No collide", Type = "boolean", Default = false},
		{
			Key = "Width",
			Text = "Width",
			Type = "number",
			Default = 0.015,
			Min = 0,
			Max = 0.3,
			Precision = 3,
		},
		{
			Key = "Color",
			Text = "Color",
			Type = "color",
			Default = Color(0.6, 0.62, 0.65, 1),
		},
	},
	Build = function(context, first, second)
		local point0 = toolgun.GetTargetPosition(first)
		local point1 = toolgun.GetTargetPosition(second)
		local axis = point1 - point0

		if axis:GetLength() < 0.001 then axis = toolgun.GetTargetNormal(first) end

		return {
			Kind = "slider",
			Friction = context:GetSetting("Friction"),
			CollideConnected = not context:GetSetting("NoCollide"),
			Width = context:GetSetting("Width"),
			Color = context:GetSetting("Color"):Copy(),
		},
		point0,
		point1,
		axis:GetNormalized()
	end,
}
