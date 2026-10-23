local toolgun = import("lua/toolgun.lua")
return toolgun.ConstraintTool{
	Name = "ball_socket",
	DisplayName = "Ball socket",
	Kind = "ball_socket",
	Description = "Joins two objects at a point they can both swivel around.",
	Instructions = {Stages = {"select the first object", "select the pivot on the second object"}},
	Settings = {
		{Key = "NoCollide", Text = "No collide", Type = "boolean", Default = true},
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
		local point = toolgun.GetTargetPosition(second)
		return {
			Kind = "ball_socket",
			CollideConnected = not context:GetSetting("NoCollide"),
			BreakForce = context:GetSetting("ForceLimit"),
		},
		point,
		point
	end,
}
