local Quat = import("goluwa/structs/quat.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local event = import("goluwa/event.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local input = import("goluwa/input.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local sun = Entity.New{
	transform = {
		Rotation = Quat(-0.2, 0.8, 0.4, 0.4),
	},
	light = {
		LightType = "sun",
		Color = Color(1.0, 0.98, 1),
		Intensity = 0.035,
	},
}
sun.light:SetCastShadows{
	size = Vec2() + 2048,
	cascade_count = 3,
	cascade_sizes = {
		Vec2() + 4096,
		Vec2() + 2048,
		Vec2() + 2048,
	},
	cascade_zoom_factors = {
		2,
		1.5,
		1,
	},
	cascade_split_lambda = 0.2,
	max_shadow_distance = 2700,
	near_plane = 1,
	far_plane = 2700,
}

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

	rot:Normalize()
	sun.transform:SetRotation(rot)
	local sunDir = -rot:GetForward()
	local sunColor = atmosphere.GetSunColor(sunDir)
	sun.light:SetColor(Color(sunColor:Unpack()))
end)
