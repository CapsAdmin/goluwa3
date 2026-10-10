local objects = import("goluwa/objects/objects.lua")
local input = import("goluwa/input.lua")
local META = objects.CreateTemplate("weapon_camera")

function META:Initialize()
	local weapon = self.Owner.weapon
	weapon:SetSlot(3)
	weapon:SetDisplayName("Camera")
	weapon:SetModelPrefab("weapon_camera_model")
	weapon:SetHiddenInFirstPerson(true)
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
