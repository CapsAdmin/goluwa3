local objects = import("goluwa/objects/objects.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local biped = import("lua/biped.lua")
local eye_pose = import("lua/eye_pose.lua")
local META = objects.CreateTemplate("procedural_pose")
-- an empty Network table is what makes the component part of the spawn packet
META.Network = {}

function META:Initialize()
	if self.initialized then return end

	self.initialized = true
	self.state = eye_pose.New()
	self.bones = {}

	for _, entry in ipairs(biped.Bones) do
		self.bones[entry[1]] = Matrix44()
	end

	self:AddGlobalEvent("Update")
end

function META:GetBones()
	if not self.computed then
		self.computed = true
		eye_pose.Compute(self.state, self.bones, self.Owner, 0)
	end

	return self.bones
end

function META:OnArmatureRebuild()
	self.grip_weapon = nil
end

function META:OnUpdate(dt)
	local owner = self.Owner
	local armature = owner.armature
	local ragdoll = owner.ragdoll

	if owner.character_pose.driver then return end

	if not armature and not (ragdoll and ragdoll.Profile == "eye") then return end

	if ragdoll and ragdoll:IsReleased() then
		if not armature then return end

		ragdoll:ReadBones(self.bones)
	else
		self.computed = true
		eye_pose.Compute(self.state, self.bones, owner, dt)
	end

	if not armature then return end

	for _, entry in ipairs(biped.Bones) do
		armature:SetBone(entry[1], self.bones[entry[1]], "model")
	end

	local holder = owner.weapon_holder
	local active = holder and holder:GetActiveWeapon()
	local path = active and active.prefab.Path

	if path ~= self.grip_weapon then
		self.grip_weapon = path
		local grip = path and (eye_pose.Grips[path] or eye_pose.DefaultGrip).right
		armature:SetSocket("grip_r", "hand_r", grip and grip * -1)
	end
end

return META:Register()
