local toolgun = import("lua/toolgun.lua")
local game_history = import("lua/game_history.lua")
local MATERIALS = {
	{Name = "metal", Friction = 0.6, Restitution = 0.2},
	{Name = "wood", Friction = 0.8, Restitution = 0.25},
	{Name = "concrete", Friction = 0.9, Restitution = 0.15},
	{Name = "dirt", Friction = 0.9, Restitution = 0},
	{Name = "glass", Friction = 0.4, Restitution = 0.2},
	{Name = "rubber", Friction = 1.2, Restitution = 0.6},
	{Name = "bouncy", Friction = 0.6, Restitution = 0.95},
	{Name = "ice", Friction = 0.02, Restitution = 0.1},
	{Name = "slime", Friction = 0, Restitution = 0},
}
local options = {}
local by_name = {}

for i, material in ipairs(MATERIALS) do
	options[i] = {Text = material.Name, Value = material.Name}
	by_name[material.Name] = material
end

return toolgun.Register{
	Name = "physical_properties",
	DisplayName = "Physical properties",
	Category = "Physics",
	Description = "Sets the surface material and gravity of an object.",
	Instructions = {Left = "apply the properties", Right = "copy the gravity of an object"},
	Settings = {
		{
			Key = "Material",
			Text = "Material",
			Type = "enum",
			Default = "metal",
			Options = options,
		},
		{Key = "Gravity", Text = "Gravity", Type = "boolean", Default = true},
	},
	LeftClick = function(context, trace)
		if not toolgun.IsProp(trace.entity) then return false end

		local material = by_name[context:GetSetting("Material")]
		context:Record(
			game_history.Change(
				"physical properties",
				trace.entity,
				"rigid_body",
				{
					Friction = material.Friction,
					Restitution = material.Restitution,
					RestitutionCombineMode = "max",
					GravityScale = context:GetSetting("Gravity") and 1 or 0,
				}
			)
		)
		trace.entity.rigid_body:Wake()
		return true
	end,
	RightClick = function(context, trace)
		if not toolgun.IsProp(trace.entity) then return false end

		if context:GetPlayer() == _G.PLAYER_RIG then
			toolgun.SetSetting("physical_properties", "Gravity", trace.entity.rigid_body:GetGravityScale() ~= 0)
		end

		return true
	end,
}
