local prefab = import("goluwa/entities/prefab.lua")
local outfit_source = {}
outfit_source.Model = "models/player/kleiner.mdl"
outfit_source.Bones = {
	body = "ValveBiped.Bip01_Pelvis",
	spine = "ValveBiped.Bip01_Spine1",
	chest = "ValveBiped.Bip01_Spine2",
	neck = "ValveBiped.Bip01_Neck1",
	head = "ValveBiped.Bip01_Head1",
	clavicle_r = "ValveBiped.Bip01_R_Clavicle",
	upperarm_r = "ValveBiped.Bip01_R_UpperArm",
	forearm_r = "ValveBiped.Bip01_R_Forearm",
	hand_r = "ValveBiped.Bip01_R_Hand",
	clavicle_l = "ValveBiped.Bip01_L_Clavicle",
	upperarm_l = "ValveBiped.Bip01_L_UpperArm",
	forearm_l = "ValveBiped.Bip01_L_Forearm",
	hand_l = "ValveBiped.Bip01_L_Hand",
	thigh_r = "ValveBiped.Bip01_R_Thigh",
	calf_r = "ValveBiped.Bip01_R_Calf",
	foot_r = "ValveBiped.Bip01_R_Foot",
	thigh_l = "ValveBiped.Bip01_L_Thigh",
	calf_l = "ValveBiped.Bip01_L_Calf",
	foot_l = "ValveBiped.Bip01_L_Foot",
}
outfit_source.Script = [[
local objects = import("goluwa/objects/objects.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")

local UNIT = import("goluwa/source_engine/units.lua").meters
local WALK_SPEED = 100 * UNIT
local RUN_SPEED = 200 * UNIT
local HEAD_PITCH_SHARE = 0.6
local NECK_PITCH_SHARE = 0.4
local WEAPONS = {weapon_camera = "camera", weapon_physgun = "physgun", weapon_pistol = "pistol"}
local matrix = Matrix44()
local pitch_matrix = Matrix44()
local META = objects.CreateTemplate("outfit_source")

function META:Initialize()
	local entity = self.Owner
	assert(entity.animator, "outfit_source needs an animator on its entity")
	assert(entity.model, "outfit_source needs a model on its entity")
	assert(type(OUTFIT_BONES) == "table" and next(OUTFIT_BONES), "outfit_source needs OUTFIT_BONES defined before the script")
	self.move_x = 0
	self.move_y = 0
	self.sequence = ""
	self:AddGlobalEvent("Update")
end

function META:OnRemove()
	if self.player and self.player:IsValid() then
		self.player.player_avatar:SetBonesDriven(false)
	end
end

-- the parent is set after the prefab is built, so the player is looked up the first frames
local function find_player(entity)
	local node = entity:GetParent()
	while node:IsValid() do
		if node.player_avatar then return node end
		node = node:GetParent()
	end
end

local function weapon_suffix(script)
	local holder = script.player and script.player.weapon_holder
	local weapon = holder and holder:GetActiveWeapon()
	return weapon and WEAPONS[weapon.prefab.Path] or "all"
end

function META:OnUpdate(dt)
	local entity = self.Owner
	local animator = entity.animator
	local rig = animator and animator:GetRig()
	if not rig or dt <= 0 then return end

	if not self.player then
		self.player = find_player(entity)
		if self.player then self.player.player_avatar:SetBonesDriven(true) end
	end

	local player = self.player or entity:GetParent()
	if not player:IsValid() then return end
	local transform = player.transform
	local _, rotation = transform:GetRenderPositionRotation()
	rotation = rotation or transform:GetRotation()
	local body = self.player and self.player.rigid_body
	local velocity = body and body:GetVelocity() or transform:GetRenderVelocity()
	local forward_speed = velocity:Dot(rotation:GetForward())
	local right_speed = velocity:Dot(rotation:GetRight())
	local speed = math.sqrt(forward_speed * forward_speed + right_speed * right_speed)
	local crouching = self.player and self.player.player_avatar:IsCrouching()
	local air = math.abs(velocity.y) > 0.8
	if body and body:GetGrounded() then air = false end

	local suffix = weapon_suffix(self)
	local sequence
	local reference = crouching and WALK_SPEED * 0.6 or (speed > WALK_SPEED * 1.4 and RUN_SPEED or WALK_SPEED)
	local rate = 1

	if air then
		sequence = "jump_" .. suffix
	elseif speed < 0.15 then
		sequence = (crouching and "cidle_" or "idle_") .. suffix
		if suffix == "all" then sequence = crouching and "cidle_all" or "idle_all_01" end
	elseif crouching then
		sequence = "cwalk_" .. suffix
	elseif reference == RUN_SPEED then
		sequence = suffix == "all" and "run_all_01" or "run_" .. suffix
	else
		sequence = "walk_" .. suffix
	end

	if sequence ~= self.sequence then
		self.sequence = sequence
		animator:SetLoop(not air)
		animator:SetSequence(sequence)
		if air then animator:Restart() end
	end

	if speed >= 0.15 and not air then rate = math.clamp(speed / reference, 0.4, 2) end
	animator:SetSpeed(rate)

	local follow = math.min(dt * 10, 1)
	self.move_x = self.move_x + (forward_speed / reference - self.move_x) * follow
	self.move_y = self.move_y + (-right_speed / reference - self.move_y) * follow
	animator:SetPoseParameterByName("move_x", math.clamp(self.move_x, -1, 1))
	animator:SetPoseParameterByName("move_y", math.clamp(self.move_y, -1, 1))
	animator:SetPoseParameterByName("vertical_velocity", math.clamp(velocity.y / 4, -1, 1))

	if not self.player then return end

	local avatar = self.player.player_avatar
	local armature = avatar.armature
	if not armature then return end

	local pitch = avatar.pitch
	for name, source in pairs(OUTFIT_BONES) do
		matrix = rig:GetBone(source)
		if name == "head" or name == "neck" then
			-- the view only turns the head and neck, in model space around the joint
			local share = name == "head" and HEAD_PITCH_SHARE or NECK_PITCH_SHARE
			local x, y, z = matrix.m30, matrix.m31, matrix.m32
			pitch_matrix:Identity()
			pitch_matrix:SetRotation(Quat(0, 0, 0, 1):Lerp(share, pitch):Normalize())
			matrix:SetTranslation(0, 0, 0)
			matrix = matrix:GetMultiplied(pitch_matrix)
			matrix:SetTranslation(x, y, z)
		elseif name == "hand_r" or name == "hand_l" then
			-- a weapon points where the player looks and sits at the animated hand
			local x, y, z = matrix.m30, matrix.m31, matrix.m32
			matrix:Identity()
			matrix:SetRotation(pitch)
			matrix:SetTranslation(x, y, z)
		end
		armature:SetBone(name, matrix, "model")
	end
end

return META:Register()
]]

function outfit_source.GetDefinition()
	return {
		inputs = {},
		entities = {
			{guid = "root", components = {}},
			{
				guid = "model",
				parent = "root",
				properties = {Name = "model"},
				components = {
					transform = {},
					model = {ModelPath = outfit_source.Model},
					animator = {},
					script = {
						Source = "local OUTFIT_BONES = " .. outfit_source.BonesSource() .. "\n" .. outfit_source.Script,
					},
				},
			},
		},
	}
end

function outfit_source.BonesSource()
	local names = {}

	for name in pairs(outfit_source.Bones) do
		names[#names + 1] = name
	end

	table.sort(names)

	for i, name in ipairs(names) do
		names[i] = string.format("\t%s = %q,", name, outfit_source.Bones[name])
	end

	return "{\n" .. table.concat(names, "\n") .. "\n}"
end

outfit_source.Name = "player_outfit_source"
prefab.Register(outfit_source.Name, outfit_source.GetDefinition()).builtin = true
return outfit_source
