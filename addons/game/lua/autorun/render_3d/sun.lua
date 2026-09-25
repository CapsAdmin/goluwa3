local Quat = import("goluwa/structs/quat.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local event = import("goluwa/event.lua")
local Entity = import("goluwa/entities/entity.lua")
local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local input = import("goluwa/input.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local ShadowMap = import("goluwa/render3d/shadow_map.lua")
local SUN_TOA_ILLUMINANCE = 126000
local SHADOW_CUTOFF_TRANSMITTANCE = 1e-5
local sun = Entity.New{
	Name = "sun",
	transform = {
		Rotation = Quat(-0.2, 0.8, 0.4, 0.4),
	},
	light_sun = {
		Color = Color(1.0, 0.98, 1),
		Lux = SUN_TOA_ILLUMINANCE,
	},
}
_G.SUN_ENTITY = sun
atmosphere.SetSunIlluminance(SUN_TOA_ILLUMINANCE)
local MODE = "cascade"
local shadow_maps = {}
local shadow_policy = {
	shadow_update_mode = "continuous",
	shadow_update_interval = 2,
}

if MODE == "lispsm" then
	shadow_maps[#shadow_maps + 1] = ShadowMap.New{
		mode = "directional",
		light = sun,
		size = Vec2() + 4096,
		directional_projection_mode = "lispsm",
		min_caster_texel_size = 4,
		cascade_formats = {
			"d32_sfloat",
		},
		max_shadow_distance = 2700,
		near_plane = 1,
		far_plane = 2700,
	}
elseif MODE == "cascade" then
	shadow_maps[#shadow_maps + 1] = ShadowMap.New{
		mode = "sun",
		light = sun,
		size = Vec2() + 2048,
		cascade_count = 3,
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
		soup_cascade_from = 2,
		disable_vertex_animation_cascades = {[3] = true},
		cascade_split_lambda = 0.5,
		max_shadow_distance = 2700,
		near_plane = 1,
		far_plane = 2700,
	}
	shadow_maps[#shadow_maps + 1] = ShadowMap.New{
		mode = "sun",
		light = sun,
		size = Vec2() + 4096,
		cascade_count = 1,
		cascade_sizes = {Vec2() + 4096},
		cascade_formats = {"d16_unorm"},
		cascade_zoom_factors = {1.75},
		min_caster_texel_size = 1,
		cascade_split_lambda = 1,
		max_shadow_distance = 16,
		ortho_size = 50,
		near_plane = 1,
		far_plane = 16,
		role = "inset",
	}
	shadow_policy.farthest_cascade_update_mode = "world_changed"
	shadow_policy.farthest_cascade_camera_position_threshold = 96
end

for _, shadow_map in ipairs(shadow_maps) do
	shadow_map:SetUpdatePolicy(shadow_policy)
end

local function update_sun(rot)
	rot:Normalize()
	sun.transform:SetRotation(rot)
	local sunDir = -rot:GetForward()
	local sunColor = atmosphere.GetSunColor(sunDir)
	sun.light_sun:SetColor(Color(sunColor:Unpack()))
	local transmittance = math.max(sunColor.x, math.max(sunColor.y, sunColor.z))

	for _, shadow_map in ipairs(shadow_maps) do
		shadow_map:SetEnabled(transmittance > SHADOW_CUTOFF_TRANSMITTANCE)
	end
end

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
	else
		return
	end

	update_sun(rot)
end)
