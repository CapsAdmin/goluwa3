local nodes = import("lua/weapon_nodes.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BODY = {Color = Color(0.08, 0.08, 0.09, 1), Roughness = 0.5, Metallic = 0.3}
local HANDLE = {Color = Color(0.2, 0.2, 0.22, 1), Roughness = 0.9, Metallic = 0}
local LENS = {Color = Color(0.1, 0.25, 0.4, 1), Roughness = 0.05, Metallic = 0.9}
return {
	Values = {
		WorldSize = Vec3(0.2, 0.14, 0.21),
		WorldCenter = Vec3(-0.075, 0.015, -0.06),
		Stance = "camera",
		Slot = 3,
		DisplayName = "Camera",
		TwoHanded = true,
		SupportGrip = Vec3(-0.1, 0, -0.115),
		SupportRoll = math.pi / 2,
		HiddenInFirstPerson = true,
		HeldAtEye = true,
		HidesPlayer = true,
	},
	Nodes = {
		nodes.Handle("handle", 0.025, 0.11, Vec3(0, 0, 0), HANDLE),
		nodes.Box("body", Vec3(0.15, 0.09, 0.09), Vec3(-0.1, 0.04, -0.02), BODY),
		nodes.Muzzle(0.04, 0.1, Vec3(-0.1, 0.04, -0.165), LENS),
	},
	Source = [=====[local objects = import("goluwa/objects/objects.lua")
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
