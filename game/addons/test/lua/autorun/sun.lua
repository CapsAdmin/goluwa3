local Quat = require("structs.quat")
local render3d = require("render3d.render3d")
local Light = require("components.light")
local event = require("event")
local input = require("input")
local sun = Light.CreateDirectional(
	{
		rotation = Quat(-0.2, 0.8, 0.4, 0.4), --:SetAngles(Deg3(50, -30, 0)),
		color = {1.0, 0.98, 0.95},
		intensity = 3.0,
		name = "Sun",
		cast_shadows = true,
		shadow_config = {
			ortho_size = 5,
			near_plane = 1,
			far_plane = 500,
		},
	}
)
sun:SetIsSun(true)
sun:SetRotation(Quat(0.4, -0.1, -0.1, -0.9):Normalize())
render3d.SetLights({sun})

event.AddListener("Update", "sun_oientation", function(dt)
	if input.IsKeyDown("k") then
		local angles = sun:GetRotation():GetAngles()
		angles.x = angles.x + dt
		sun:SetRotation(Quat():SetAngles(angles))
	elseif input.IsKeyDown("l") then
		local angles = sun:GetRotation():GetAngles()
		angles.x = angles.x - dt
		sun:SetRotation(Quat():SetAngles(angles))
	end
end)
