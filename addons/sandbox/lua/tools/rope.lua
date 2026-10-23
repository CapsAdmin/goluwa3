local toolgun = import("lua/toolgun.lua")
local Color = import("goluwa/structs/color.lua")
return toolgun.ConstraintTool{
	Name = "rope",
	DisplayName = "Rope",
	Kind = "rope",
	Description = "Ties two points together with a rope that can go slack.",
	Settings = {
		{
			Key = "AddLength",
			Text = "Add length",
			Type = "number",
			Default = 0,
			Min = 0,
			Max = 20,
			Precision = 2,
			Description = "slack added to the distance between the points",
		},
		{
			Key = "Rigid",
			Text = "Rigid",
			Type = "boolean",
			Default = false,
			Description = "a rod that also pushes",
		},
		{
			Key = "Width",
			Text = "Width",
			Type = "number",
			Default = 0.03,
			Min = 0,
			Max = 0.3,
			Precision = 3,
		},
		{
			Key = "Color",
			Text = "Color",
			Type = "color",
			Default = Color(0.35, 0.27, 0.18, 1),
		},
		{
			Key = "ForceLimit",
			Text = "Force limit",
			Type = "number",
			Default = 0,
			Min = 0,
			Max = 100000,
			Precision = 0,
		},
	},
	Build = function(context, first, second)
		local point0 = toolgun.GetTargetPosition(first)
		local point1 = toolgun.GetTargetPosition(second)
		return {
			Kind = "rope",
			Length = point0:Distance(point1) + context:GetSetting("AddLength"),
			Rigid = context:GetSetting("Rigid"),
			Width = context:GetSetting("Width"),
			Color = context:GetSetting("Color"):Copy(),
			BreakForce = context:GetSetting("ForceLimit"),
		},
		point0,
		point1
	end,
}
