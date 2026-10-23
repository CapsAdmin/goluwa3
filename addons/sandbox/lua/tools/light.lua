local toolgun = import("lua/toolgun.lua")
local game_history = import("lua/game_history.lua")
local props = import("lua/props.lua")
local Entity = import("goluwa/entities/entity.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local MODEL = "models/maxofs2d/light_tubular.mdl"
return toolgun.Register{
	Name = "light",
	DisplayName = "Light",
	Category = "Construction",
	Description = "Places a lamp, welded to whatever you click.",
	Instructions = {Left = "place a light"},
	Settings = {
		{
			Key = "Color",
			Text = "Color",
			Type = "color",
			Default = Color(1, 0.85, 0.65, 1),
		},
		{
			Key = "Lumen",
			Text = "Brightness",
			Type = "number",
			Default = 2000,
			Min = 0,
			Max = 50000,
			Precision = 0,
		},
		{
			Key = "Range",
			Text = "Range",
			Type = "number",
			Default = 12,
			Min = 0.5,
			Max = 100,
			Precision = 1,
		},
		{Key = "Weld", Text = "Weld", Type = "boolean", Default = true},
	},
	LeftClick = function(context, trace)
		if not (trace.world or toolgun.IsProp(trace.entity)) then return false end

		local player = context:GetPlayer()
		local target = toolgun.MakeTarget(trace)
		local color = context:GetSetting("Color"):Copy()
		local lumen = context:GetSetting("Lumen")
		local range = context:GetSetting("Range")
		local weld = context:GetSetting("Weld")

		props.Spawn(
			MODEL,
			trace.position,
			Quat():Identity(),
			function(lamp)
				if target.entity and not target.entity:IsValid() then
					lamp:Remove()
					return
				end

				lamp:SetOwnedBy(toolgun.GetClient(player))
				Entity.New{
					Name = "light",
					Parent = lamp,
					Transient = false,
					transform = {},
					light_point = {Color = color, Lumen = lumen, Range = range, OcclusionMap = false},
				}
				local entries = {game_history.Spawned("light", lamp)}

				if weld then
					local point = toolgun.GetTargetPosition(target)
					local constraint = toolgun.CreateConstraint(player, {entity = lamp}, target, {Kind = "weld"}, point, point)
					entries[2] = game_history.Spawned("weld", constraint)
				end

				context:Record(game_history.Group("light", entries))
			end
		)

		return true
	end,
}
