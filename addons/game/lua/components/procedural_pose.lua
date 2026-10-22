local objects = import("goluwa/objects/objects.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local biped = import("lua/biped.lua")
local eye_pose = import("lua/eye_pose.lua")
local Quat = import("goluwa/structs/quat.lua")
local META = objects.CreateTemplate("procedural_pose")
-- an empty Network table is what makes the component part of the spawn packet
META.Network = {}

local LIMP_GRIP_ROTATION = Quat(0, 0, 0, 1):Rotate(math.pi / 2, 1, 0, 0)

function META:Initialize()
	if self.initialized then return end

	self.initialized = true
	self.state = eye_pose.New()
	self.bones = {}
	self.display = {}

	for _, entry in ipairs(biped.Bones) do
		self.bones[entry[1]] = Matrix44()
		self.display[entry[1]] = Matrix44()
	end

	self:AddGlobalEvent("Update")
end

-- the pose alone, which is what the physics parts follow
function META:GetPoseBones()
	if not self.computed then
		self.computed = true
		eye_pose.Compute(self.state, self.bones, self.Owner, 0)
		self:CopyDisplay()
	end

	return self.bones
end

-- the pose with the limp parts put where their bodies are, which is what is shown
function META:GetBones()
	self:GetPoseBones()

	return self.display
end

function META:CopyDisplay()
	for name, matrix in pairs(self.bones) do
		matrix:CopyFrom(self.display[name])
	end
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

	self.computed = true
	eye_pose.Compute(self.state, self.bones, owner, dt * owner.character_pose.animation_speed)
	self:CopyDisplay()

	if not armature then return end

	if ragdoll and ragdoll:HasLimp() then ragdoll:ReadBones(self.display) end

	for _, entry in ipairs(biped.Bones) do
		armature:SetBone(entry[1], self.display[entry[1]], "model")
	end

	local holder = owner.weapon_holder
	local active = holder and holder:GetActiveWeapon()
	local path = active and active.prefab.Path
	local limp = ragdoll ~= nil and ragdoll:IsPartLimp("forearm_r")
	local key = path and (path .. (limp and "_limp" or ""))

	if key ~= self.grip_weapon then
		self.grip_weapon = key
		local grip = path and (eye_pose.Grips[path] or eye_pose.DefaultGrip).right

		if not grip then
			armature:SetSocket("grip_r", "hand_r")
		elseif limp then
			armature:SetSocket("grip_r", "forearm_r", Vec3(0, eye_pose.ArmLength * 0.5, 0) - LIMP_GRIP_ROTATION:VecMul(grip), LIMP_GRIP_ROTATION)
		else
			armature:SetSocket("grip_r", "hand_r", grip * -1)
		end
	end
end

return META:Register()
