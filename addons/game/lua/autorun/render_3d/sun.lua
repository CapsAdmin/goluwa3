local Quat = import("goluwa/structs/quat.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local event = import("goluwa/event.lua")
local Entity = import("goluwa/entities/entity.lua")
local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local input = import("goluwa/input.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local sun = Entity.New{
	Name = "sun",
	transform = {
		Rotation = Quat(-0.2, 0.8, 0.4, 0.4),
	},
	light = {
		LightType = "sun",
		Color = Color(1.0, 0.98, 1),
		Intensity = 2,
	},
}
atmosphere.SetSunIntensity(sun.light.Intensity)
local MODE = "cascade"
local shadow_config

if MODE == "lispsm" then
	shadow_config = {
		size = Vec2() + 4096,
		directional_projection_mode = "lispsm",
		min_caster_texel_size = 4,
		shadow_update_interval = 2,
		cascade_formats = {
			"d32_sfloat",
		},
		max_shadow_distance = 2700,
		near_plane = 1,
		far_plane = 2700,
	}
elseif MODE == "cascade" then
	shadow_config = {
		size = Vec2() + 2048,
		min_caster_texel_size = 4,
		shadow_update_interval = 2,
		cascade_count = 3,
		soup_cascade_from = 2,
		cascade_formats = {
			"d16_unorm",
			"d16_unorm",
			"d16_unorm",
		},
		cascade_sizes = {
			Vec2() + 2048,
			Vec2() + 2048,
			Vec2() + 2048,
		},
		cascade_zoom_factors = {
			3,
			1.5,
			1,
		},
		farthest_cascade_update_mode = "world_changed",
		farthest_cascade_camera_position_threshold = 96,
		farthest_cascade_disable_vertex_animation = true,
		cascade_split_lambda = 0.5,
		max_shadow_distance = 2700,
		inset_shadows = {
			size = Vec2() + 4096,
			cascade_formats = {"d16_unorm"},
			distance = 16,
			min_caster_texel_size = 1,
			zoom_factor = 1.75,
		},
		near_plane = 1,
		far_plane = 2700,
	}
end

if shadow_config then sun.light:SetCastShadows(shadow_config) end

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
	local below_horizon = sunDir.y < 0

	if below_horizon then
		if sun.light:GetCastShadows() then
			sun.light.BelowHorizon = true
			sun.light:SetIntensity(0)
			sun.light:SetCastShadows(false)
		end
	else
		if not sun.light:GetCastShadows() then
			sun.light.BelowHorizon = false
			sun.light:SetIntensity(2)
			sun.light:SetCastShadows(shadow_config)
		end
	end

	atmosphere.SetSunIntensity(sun.light.Intensity)
	local sunColor = atmosphere.GetSunColor(sunDir)
	sun.light:SetColor(Color(sunColor:Unpack()))
end)
