local objects = import("goluwa/objects/objects.lua")
local input = import("goluwa/input.lua")
local META = objects.CreateTemplate("weapon_camera")

function META:WeaponMouseLook(player_input, mouse_delta)
	if not input.IsMouseDown("button_2") then return end

	local rotation = player_input:GetRotation():Copy()
	rotation:RotateRoll(mouse_delta.x)
	self.roll = (self.roll or 0) + mouse_delta.x
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

function META:WeaponReset(player_input)
	player_input:ResetFOV()
	return true
end

function META:WeaponHolster()
	local player_input = self.Owner:GetParent().player_input
	local rotation = player_input:GetRotation():Copy()
	rotation:RotateRoll(-(self.roll or 0))
	player_input:SetRotation(rotation)
	self.roll = 0
	player_input:ResetFOV()
end

return META:Register()
