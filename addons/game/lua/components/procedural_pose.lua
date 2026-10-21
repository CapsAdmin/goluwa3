local objects = import("goluwa/objects/objects.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local aim_pose = import("lua/aim_pose.lua")
local UNIT = import("goluwa/source_engine/units.lua").meters
local META = objects.CreateTemplate("procedural_pose")
-- an empty Network table is what makes the component part of the spawn packet
META.Network = {}
local HEIGHT = 72 * UNIT
local CROUCH_HEIGHT = 36 * UNIT
local EYE_HEIGHT = 64 * UNIT
local CROUCH_EYE_HEIGHT = 28 * UNIT
local WEAPON_RAISE = 0.12
local WEAPON_FORWARD = 0.12
local HAND_SPACING = 0.22
local EYE_HOLD_BACK = 0.14
local bone_matrix = Matrix44()

function META:Initialize()
	self:AddGlobalEvent("Update")
end

function META:OnUpdate()
	local owner = self.Owner
	local armature = owner.armature
	local pose = owner.character_pose

	if not armature or pose.driver then return end

	local pitch = aim_pose.GetAim(pose)
	local crouch_alpha = pose.crouch_alpha
	local eye = math.lerp(crouch_alpha, EYE_HEIGHT, CROUCH_EYE_HEIGHT)
	bone_matrix:Identity()
	bone_matrix:SetRotation(pitch)
	bone_matrix:SetTranslation(0, eye, 0)
	armature:SetBone("head", bone_matrix, "local")
	local forward = pitch:GetForward()
	local holder = owner.weapon_holder
	local active = holder and holder:GetActiveWeapon()
	local hand

	if active and active.weapon:IsHeldAtEye() then
		hand = Vec3(0, eye, 0) - forward * EYE_HOLD_BACK
	else
		hand = Vec3(0, math.lerp(crouch_alpha, HEIGHT, CROUCH_HEIGHT) * 0.5 + WEAPON_RAISE, 0) + forward * WEAPON_FORWARD
	end

	bone_matrix:SetTranslation(hand.x, hand.y, hand.z)
	armature:SetBone("hand_r", bone_matrix, "local")
	hand = hand - pitch:GetRight() * HAND_SPACING
	bone_matrix:SetTranslation(hand.x, hand.y, hand.z)
	armature:SetBone("hand_l", bone_matrix, "local")
end

return META:Register()
