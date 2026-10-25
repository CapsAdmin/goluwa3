local nodes = import("lua/weapon_nodes.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local CAMERA_BODY = {Color = Color(0.1, 0.1, 0.11, 1), Roughness = 0.5, Metallic = 0.3}
local GLASS = {Color = Color(0.1, 0.25, 0.4, 1), Roughness = 0.05, Metallic = 0.9}
local ACCENT = {Color = Color(0.7, 0.7, 0.72, 1), Roughness = 0.4, Metallic = 0.8}
local box = nodes.Box
local muzzle = nodes.Muzzle
return {
	Values = {
		WorldSize = Vec3(0.16, 0.1, 0.34),
		WorldCenter = FORWARD * 0.2,
		Slot = 3,
		DisplayName = "Camera",
		TwoHanded = true,
		HiddenInFirstPerson = true,
		HeldAtEye = true,
		HidesPlayer = true,
	},
	Nodes = {
		box("body", Vec3(0.16, 0.1, 0.12), FORWARD * 0.22, CAMERA_BODY),
		box("lens", Vec3(0.075, 0.075, 0.09), FORWARD * 0.33, GLASS),
		box("ring", Vec3(0.09, 0.09, 0.03), FORWARD * 0.385, ACCENT),
		box("button", Vec3(0.05, 0.03, 0.05), FORWARD * 0.2 + Vec3(0, 0.065, 0), ACCENT),
		muzzle(0.4),
	},
	Source = [=====[
local objects = import("goluwa/objects/objects.lua")
local input = import("goluwa/input.lua")
local render2d = RENDER_2D and import("goluwa/render2d/render2d.lua")
local META = objects.CreateTemplate("weapon_camera")

function META:OnWeaponMouseLook(player_input, mouse_delta)
	if not input.IsMouseDown("button_2") then return end

	local rotation = player_input:GetRotation():Copy()
	rotation:RotateRoll(-mouse_delta.x)
	self.roll = (self.roll or 0) - mouse_delta.x
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

function META:OnWeaponReset(player_input)
	local rotation = player_input:GetRotation():Copy()
	rotation:RotateRoll(-(self.roll or 0))
	player_input:SetRotation(rotation)
	self.roll = 0
	player_input:ResetFOV()
end

function META:OnWeaponEquip()
	if RENDER_2D then render2d.SetHudHidden("weapon_camera", true) end
end

function META:OnRemove()
	if RENDER_2D then render2d.SetHudHidden("weapon_camera", false) end
end

function META:OnWeaponHolster()
	if RENDER_2D then render2d.SetHudHidden("weapon_camera", false) end

	local player_input = self.Owner:GetParent().player_input

	if not player_input then return end

	local rotation = player_input:GetRotation():Copy()
	rotation:RotateRoll(-(self.roll or 0))
	player_input:SetRotation(rotation)
	self.roll = 0
	player_input:ResetFOV()
end

return META:Register()
]=====],
}
