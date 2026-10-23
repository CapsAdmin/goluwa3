local toolgun = import("lua/toolgun.lua")
return toolgun.ConstraintTool{
	Name = "axis",
	DisplayName = "Axis",
	Kind = "axis",
	Description = "Lets the first object spin around the surface normal where you clicked it, held by the second object.",
	Instructions = {Stages = {"select the point to spin around", "select the object it is held by"}},
	Settings = {
		{
			Key = "Friction",
			Text = "Friction",
			Type = "number",
			Default = 0,
			Min = 0,
			Max = 1000,
			Precision = 1,
			Description = "torque needed to turn the axis",
		},
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
		local point = toolgun.GetTargetPosition(first)
		return {
			Kind = "axis",
			Friction = context:GetSetting("Friction"),
			CollideConnected = not context:GetSetting("NoCollide"),
			BreakForce = context:GetSetting("ForceLimit"),
		},
		point,
		point,
		toolgun.GetTargetNormal(first)
	end,
}
