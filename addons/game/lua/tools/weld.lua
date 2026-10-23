local toolgun = import("lua/toolgun.lua")
return toolgun.ConstraintTool{
	Name = "weld",
	DisplayName = "Weld",
	Kind = "weld",
	Description = "Rigidly joins two objects, or an object to the world.",
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
			Description = "the weld breaks above this force, 0 never breaks",
		},
	},
	Build = function(context, first, second)
		local point = toolgun.GetTargetPosition(second)
		return {
			Kind = "weld",
			CollideConnected = not context:GetSetting("NoCollide"),
			BreakForce = context:GetSetting("ForceLimit"),
		},
		point,
		point
	end,
}
