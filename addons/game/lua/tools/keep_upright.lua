local toolgun = import("lua/toolgun.lua")
local game_history = import("lua/game_history.lua")
local UP = import("goluwa/structs/vec3.lua")(0, 1, 0)
return toolgun.Register{
	Name = "keep_upright",
	DisplayName = "Keep upright",
	Category = "Constraints",
	Kind = "keep_upright",
	Description = "Keeps the side of an object that faces up now facing up.",
	Instructions = {Left = "keep an object upright", Reload = "stop keeping an object upright"},
	Settings = {
		{
			Key = "Torque",
			Text = "Max torque",
			Type = "number",
			Default = 0,
			Min = 0,
			Max = 100000,
			Precision = 0,
			Description = "0 is unlimited",
		},
	},
	LeftClick = function(context, trace)
		if
			not toolgun.IsProp(trace.entity) or
			toolgun.GetConstraints(trace.entity, "keep_upright")[1]
		then
			return false
		end

		local target = toolgun.MakeTarget(trace)
		local entity = toolgun.CreateConstraint(
			context:GetPlayer(),
			target,
			{position = target.position},
			{Kind = "keep_upright", MotorTorque = context:GetSetting("Torque")},
			target.position,
			target.position,
			UP
		)
		context:Record(game_history.Spawned("keep upright", entity))
		return true
	end,
	Reload = toolgun.RemoveConstraintsReload,
}
