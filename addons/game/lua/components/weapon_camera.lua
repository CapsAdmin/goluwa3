local objects = import("goluwa/objects/objects.lua")
local input = import("goluwa/input.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local META = objects.CreateTemplate("weapon_camera")

function META:Initialize()
	local weapon = self.Owner.weapon
	weapon:SetSlot(3)
	weapon:SetDisplayName("Camera")
	weapon:SetMuzzleDistance(0.4)
	weapon:SetHiddenInFirstPerson(true)
end

function META:WeaponCreateModel()
	local shapes = import("goluwa/render3d/shapes.lua")
	local weapon = self.Owner.weapon
	local body = shapes.Material{Color = Color(0.1, 0.1, 0.11, 1), Roughness = 0.5, Metallic = 0.3}
	local glass = shapes.Material{Color = Color(0.1, 0.25, 0.4, 1), Roughness = 0.05, Metallic = 0.9}
	local accent = shapes.Material{Color = Color(0.7, 0.7, 0.72, 1), Roughness = 0.4, Metallic = 0.8}
	weapon:AddModelBox(Vec3(0.16, 0.1, 0.12), FORWARD * 0.22, body)
	weapon:AddModelBox(Vec3(0.075, 0.075, 0.09), FORWARD * 0.33, glass)
	weapon:AddModelBox(Vec3(0.09, 0.09, 0.03), FORWARD * 0.385, accent)
	weapon:AddModelBox(Vec3(0.05, 0.03, 0.05), FORWARD * 0.2 + Vec3(0, 0.065, 0), accent)
end

function META:WeaponMouseLook(player_input, mouse_delta)
	if not input.IsMouseDown("button_2") then return end

	local rotation = player_input:GetRotation():Copy()
	rotation:RotateRoll(mouse_delta.x)
	player_input:SetRotation(rotation)
	player_input:SetFOV(
		math.clamp(
			player_input.FOV + mouse_delta.y * 10 * (player_input.FOV / math.pi),
			player_input.MinFOV,
			player_input.MaxFOV
		)
	)
	return true
end

return META:Register()
