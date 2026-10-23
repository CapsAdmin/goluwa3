local toolgun = import("lua/toolgun.lua")
local game_history = import("lua/game_history.lua")
return toolgun.Register{
	Name = "weight",
	DisplayName = "Weight",
	Category = "Physics",
	Description = "Changes the mass of an object.",
	Instructions = {Left = "set the mass", Right = "copy the mass of an object"},
	Settings = {
		{
			Key = "Mass",
			Text = "Mass",
			Type = "number",
			Default = 50,
			Min = 0.1,
			Max = 50000,
			Precision = 1,
		},
	},
	LeftClick = function(context, trace)
		if not toolgun.IsProp(trace.entity) then return false end

		local body = trace.entity.rigid_body
		local mass = context:GetSetting("Mass")
		local values = {Mass = mass, AutomaticMass = false}

		if body:GetInertia() then
			values.Inertia = body:GetInertia() * (mass / body:GetMass())
		end

		context:Record(game_history.Change("weight", trace.entity, "rigid_body", values))
		body:Wake()
		return true
	end,
	RightClick = function(context, trace)
		if not toolgun.IsProp(trace.entity) then return false end

		if context:GetPlayer() == _G.PLAYER_RIG then
			toolgun.SetSetting("weight", "Mass", math.round(trace.entity.rigid_body:GetMass(), 1))
		end

		return true
	end,
}
