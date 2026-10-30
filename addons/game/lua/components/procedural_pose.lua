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
local GRIP_SIDES = {
	{where = "right", socket = "grip_r", forearm = "forearm_r", hand = "hand_r"},
	{where = "left", socket = "grip_l", forearm = "forearm_l", hand = "hand_l"},
}

function META:Initialize()
	if self.initialized then return end

	self.initialized = true
	self.state = eye_pose.New()
	self.bones = {}
	self.display = {}
	self.grip_keys = {}

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
	self.grip_keys = {}
end

function META:OnUpdate(dt)
	local owner = self.Owner
	local armature = owner.armature
	local ragdoll = owner.ragdoll

	if owner.character_pose.driver then return end

	if not armature and not (ragdoll and ragdoll.Profile == "eye") then return end

	self.computed = true
	eye_pose.Compute(
		self.state,
		self.bones,
		owner,
		dt * owner.character_pose:GetTimeScale() * owner.character_pose.rate_variation
	)
	self:CopyDisplay()

	if not armature then return end

	if ragdoll and ragdoll:HasLimp() then ragdoll:ReadBones(self.display) end

	for _, entry in ipairs(biped.Bones) do
		armature:SetBone(entry[1], self.display[entry[1]], "model")
	end

	local holder = owner.weapon_holder

	for _, side in ipairs(GRIP_SIDES) do
		local weapon = holder and holder:GetWeapon(side.where)
		local path = weapon and weapon.prefab.Path
		local limp = ragdoll ~= nil and ragdoll:IsPartLimp(side.forearm)
		local key = path and (path .. (limp and "_limp" or ""))

		if key ~= self.grip_keys[side.socket] then
			self.grip_keys[side.socket] = key

			if path and limp then
				armature:SetSocket(side.socket, side.forearm, Vec3(0, eye_pose.ArmLength * 0.5, 0), LIMP_GRIP_ROTATION)
			else
				armature:SetSocket(side.socket, side.hand)
			end
		end
	end
end

return META:Register()
