local toolgun = import("lua/toolgun.lua")
local game_history = import("lua/game_history.lua")
local props = import("lua/props.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local MODEL = "models/maxofs2d/balloon_classic.mdl"
local UP = Vec3(0, 1, 0)
return toolgun.Register{
	Name = "balloon",
	DisplayName = "Balloon",
	Category = "Construction",
	Description = "Ties a balloon that pulls upwards to an object or the world.",
	Instructions = {Left = "tie a balloon"},
	Settings = {
		{
			Key = "Lift",
			Text = "Lift",
			Type = "number",
			Default = 20,
			Min = 0,
			Max = 2000,
			Precision = 0,
			Description = "the mass in kg the balloon can hold up",
		},
		{
			Key = "Length",
			Text = "Rope length",
			Type = "number",
			Default = 1.5,
			Min = 0.1,
			Max = 10,
			Precision = 2,
		},
	},
	LeftClick = function(context, trace)
		if not (trace.world or toolgun.IsProp(trace.entity)) then return false end

		local player = context:GetPlayer()
		local target = toolgun.MakeTarget(trace)
		local length = context:GetSetting("Length")
		local lift = context:GetSetting("Lift")
		local knot = trace.position + UP * length

		props.Spawn(
			MODEL,
			knot,
			Quat():Identity(),
			function(balloon)
				if target.entity and not target.entity:IsValid() then
					balloon:Remove()
					return
				end

				local body = balloon.rigid_body
				balloon:SetOwnedBy(toolgun.GetClient(player))
				body:SetGravityScale(-lift / body:GetMass())
				body:SetAirLinearDamping(1)
				body:SetLinearDamping(1)
				local rope = toolgun.CreateConstraint(
					player,
					{entity = balloon},
					target,
					{Kind = "rope", Length = length, Width = 0.01, Color = Color(0.9, 0.9, 0.9, 1)},
					knot,
					toolgun.GetTargetPosition(target)
				)
				context:Record(
					game_history.Group(
						"balloon",
						{game_history.Spawned("balloon", balloon), game_history.Spawned("rope", rope)}
					)
				)
			end
		)

		return true
	end,
}
