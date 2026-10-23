local toolgun = import("lua/toolgun.lua")
local Color = import("goluwa/structs/color.lua")
return toolgun.ConstraintTool{
	Name = "elastic",
	DisplayName = "Elastic",
	Kind = "elastic",
	Description = "Connects two points with a spring that pulls them back to their current distance.",
	Settings = {
		{
			Key = "Stiffness",
			Text = "Stiffness",
			Type = "number",
			Default = 1000,
			Min = 1,
			Max = 50000,
			Precision = 0,
			Description = "force per meter of stretch",
		},
		{
			Key = "Damping",
			Text = "Damping",
			Type = "number",
			Default = 100,
			Min = 0,
			Max = 5000,
			Precision = 0,
		},
		{
			Key = "Stretch",
			Text = "Rest length",
			Type = "number",
			Default = 1,
			Min = 0,
			Max = 4,
			Precision = 2,
			Description = "rest length as a multiple of the current distance",
		},
		{
			Key = "Width",
			Text = "Width",
			Type = "number",
			Default = 0.04,
			Min = 0,
			Max = 0.3,
			Precision = 3,
		},
		{
			Key = "Color",
			Text = "Color",
			Type = "color",
			Default = Color(0.15, 0.15, 0.17, 1),
		},
	},
	Build = function(context, first, second)
		local point0 = toolgun.GetTargetPosition(first)
		local point1 = toolgun.GetTargetPosition(second)
		return {
			Kind = "elastic",
			Length = point0:Distance(point1) * context:GetSetting("Stretch"),
			Stiffness = context:GetSetting("Stiffness"),
			Damping = context:GetSetting("Damping"),
			Width = context:GetSetting("Width"),
			Color = context:GetSetting("Color"):Copy(),
		},
		point0,
		point1
	end,
}
