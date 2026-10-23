local toolgun = import("lua/toolgun.lua")
return toolgun.ConstraintTool{
	Name = "motor",
	DisplayName = "Motor",
	Kind = "motor",
	Description = "An axis that keeps spinning the first object around the surface normal where you clicked it.",
	Instructions = {
		Stages = {"select the point to spin around", "select the object it is driven by"},
	},
	Settings = {
		{
			Key = "Speed",
			Text = "Speed",
			Type = "number",
			Default = 6,
			Min = -60,
			Max = 60,
			Precision = 1,
			Description = "radians per second, negative spins the other way",
		},
		{
			Key = "Torque",
			Text = "Torque",
			Type = "number",
			Default = 2000,
			Min = 0,
			Max = 200000,
			Precision = 0,
		},
		{Key = "NoCollide", Text = "No collide", Type = "boolean", Default = true},
	},
	Build = function(context, first, second)
		local point = toolgun.GetTargetPosition(first)
		return {
			Kind = "motor",
			MotorSpeed = context:GetSetting("Speed"),
			MotorTorque = context:GetSetting("Torque"),
			CollideConnected = not context:GetSetting("NoCollide"),
		},
		point,
		point,
		toolgun.GetTargetNormal(first)
	end,
}
