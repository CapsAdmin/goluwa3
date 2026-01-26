local Quat = require("structs.quat")
local render3d = require("render3d.render3d")
local event = require("event")
local ecs = require("ecs.ecs")
local Color = require("structs.color")
local input = require("input")
local transform = require("ecs.components.3d.transform")
local light = require("ecs.components.3d.light")
local sun = ecs.CreateFromTable(
	{
		[transform] = {
			Rotation = Quat(-0.2, 0.8, 0.4, 0.4),
		},
		[light] = {
			LightType = "sun",
			Color = Color(1.0, 0.98, 1),
			Intensity = 20,
		},
	}
)

event.AddListener("Update", "sun_orientation", function(dt)
	if not sun or not sun:IsValid() or not sun.transform then return end

	local rot = sun.transform:GetRotation()

	if input.IsKeyDown("m") then
		rot:RotateYaw(dt)
	elseif input.IsKeyDown(",") then
		rot:RotateYaw(-dt)
	elseif input.IsKeyDown("k") then
		rot:RotatePitch(dt)
	elseif input.IsKeyDown("l") then
		rot:RotatePitch(-dt)
	end

	sun.transform:SetRotation(rot:GetNormalized())
end)
