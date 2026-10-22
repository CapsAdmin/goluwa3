local objects = import("goluwa/objects/objects.lua")
local biped = import("lua/biped.lua")
local aim_pose = import("lua/aim_pose.lua")
local UNIT = import("goluwa/source_engine/units.lua").meters
local META = objects.CreateTemplate("source_pose")
META:StartStorable()
META:GetSet("Profile", "creature")
META:GetSet("IdleSequence", "")
META:GetSet("WalkSequence", "")
META:GetSet("RunSequence", "")
META:IsSet("Mirror", false)
META:IsSet("OwnsArmature", false)
META:GetSet("SocketProfile", "source_humanoid")
META:EndStorable()
local START_SPEED = 0.3
local STOP_SPEED = 0.12
local RUN_MARGIN = 1.1
local YAW_FOLLOW = 10
local MIN_RATE = 0.3
local MAX_RATE = 2.5
local PLAYER_WALK_SPEED = 100 * UNIT
local PLAYER_RUN_SPEED = 200 * UNIT
local WEAPON_SUFFIX = {weapon_camera = "camera", weapon_physgun = "physgun", weapon_pistol = "pistol"}

function META:Initialize()
	-- a source_pose in a prefab is initialized once more when the build of its entity ends
	if self.initialized then return end

	self.initialized = true
	self.state = "idle"
	self.move_yaw = 0
	self.move_x = 0
	self.move_y = 0
	self.sequence = ""
	self.bones = {}

	if RENDER_3D and self.OwnsArmature then
		self.Owner:EnsureComponent("armature", {Skeleton = biped.SkeletonName})
	end

	self:AddGlobalEvent("Update")
end

function META:OnRemove()
	if self.character and self.character:IsValid() then self.character.character_pose.driver = nil end
end

local function find_ancestor(entity, component)
	local node = entity

	while node:IsValid() do
		if node[component] then return node end

		node = node:GetParent()
	end
end

function META:UpdateCreature(animator, skeleton, pose, dt)
	local forward_speed = pose.forward_speed
	local left_speed = -pose.right_speed
	local speed = math.sqrt(forward_speed * forward_speed + left_speed * left_speed)
	local params = animator.pose_parameters
	local state = self.state

	if speed < (state == "idle" and START_SPEED or STOP_SPEED) then
		state = "idle"
	else
		local walk = skeleton.ClipsByName[self.WalkSequence]
		local run = skeleton.ClipsByName[self.RunSequence]

		if run and run ~= walk then
			local walk_speed = walk and walk:GetGroundSpeed(params) or 0
			local middle = (walk_speed + run:GetGroundSpeed(params)) / 2
			state = speed > middle * (
					state == "run" and
					1 / RUN_MARGIN or
					RUN_MARGIN
				)
				and
				"run" or
				"walk"
		else
			state = "walk"
		end
	end

	self.state = state
	local sequence = state == "run" and
		self.RunSequence or
		state == "walk" and
		self.WalkSequence or
		self.IdleSequence

	if sequence ~= self.sequence then
		self.sequence = sequence
		animator:SetSequence(sequence)
	end

	local clip = skeleton.ClipsByName[sequence]
	local rate = 1

	if state ~= "idle" and clip then
		local ground_speed = clip:GetGroundSpeed(params)

		if ground_speed > 0 then
			rate = math.clamp(speed / ground_speed, MIN_RATE, MAX_RATE)
		end
	end

	animator:SetSpeed(rate)
	local range = skeleton.PoseParameterRanges.move_yaw

	if range and state ~= "idle" then
		local target = math.deg(math.atan2(left_speed, forward_speed))
		local difference = (target - self.move_yaw + 180) % 360 - 180
		self.move_yaw = math.clamp(self.move_yaw + difference * math.min(dt * YAW_FOLLOW, 1), range[1], range[2])
		animator:SetPoseParameterByName("move_yaw", self.move_yaw)
	end
end

function META:UpdatePlayer(animator, pose, dt)
	local forward_speed = pose.forward_speed
	local right_speed = pose.right_speed
	local speed = math.sqrt(forward_speed * forward_speed + right_speed * right_speed)
	local crouching = pose:IsCrouching()
	local air = math.abs(pose.vertical_speed) > 0.8 and not pose.grounded
	local holder = pose.Owner.weapon_holder
	local weapon = holder and holder:GetActiveWeapon()
	local suffix = weapon and WEAPON_SUFFIX[weapon.prefab.Path] or "all"
	local sequence
	local reference = crouching and
		PLAYER_WALK_SPEED * 0.6 or
		(
			speed > PLAYER_WALK_SPEED * 1.4 and
			PLAYER_RUN_SPEED or
			PLAYER_WALK_SPEED
		)
	local rate = 1

	if air then
		sequence = "jump_" .. suffix
	elseif speed < 0.15 then
		sequence = (crouching and "cidle_" or "idle_") .. suffix

		if suffix == "all" then
			sequence = crouching and "cidle_all" or "idle_all_01"
		end
	elseif crouching then
		sequence = "cwalk_" .. suffix
	elseif reference == PLAYER_RUN_SPEED then
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

	if speed >= 0.15 and not air then
		rate = math.clamp(speed / reference, 0.4, 2)
	end

	animator:SetSpeed(rate)
	local follow = math.min(dt * 10, 1)
	self.move_x = self.move_x + (forward_speed / reference - self.move_x) * follow
	self.move_y = self.move_y + (right_speed / reference - self.move_y) * follow
	animator:SetPoseParameterByName("move_x", math.clamp(self.move_x, -1, 1))
	animator:SetPoseParameterByName("move_y", math.clamp(self.move_y, -1, 1))
	animator:SetPoseParameterByName("vertical_velocity", math.clamp(pose.vertical_speed / 4, -1, 1))
end

function META:MirrorBones(rig, armature, pose)
	local holder = pose.Owner.weapon_holder
	local active = holder and holder:GetActiveWeapon()
	local armed = active ~= nil
	local bones = self.bones

	for _, name in ipairs(aim_pose.Bones) do
		rig:ClearBone(biped.SourceBones[name])
	end

	for name, source in pairs(biped.SourceBones) do
		bones[name] = rig:GetBone(source)
	end

	aim_pose.Apply(bones, pose, armed, armed and active.weapon:IsTwoHanded())

	for _, name in ipairs(aim_pose.Bones) do
		rig:SetBone(biped.SourceBones[name], bones[name], "model")
	end

	for name in pairs(biped.SourceBones) do
		local matrix = bones[name]

		if armed and (name == "hand_r" or name == "hand_l") then
			matrix = aim_pose.GetGripMatrix(matrix, aim_pose.GetAim(pose))
		end

		armature:SetBone(name, matrix, "model")
	end
end

function META:OnUpdate(dt)
	local owner = self.Owner
	local animator = owner.animator
	local rig = animator and animator:GetRig()

	if not rig or dt <= 0 then return end

	if not self.character then
		self.character = find_ancestor(owner, "character_pose")

		if not self.character then return end

		self.character.character_pose.driver = self
	end

	local pose = self.character.character_pose

	if self.Profile == "gmod_player" then
		self:UpdatePlayer(animator, pose, dt)
	else
		self:UpdateCreature(animator, animator.skeleton, pose, dt)
	end

	local host = self.Mirror and find_ancestor(owner, "armature")

	if not host then return end

	local points = host.attachment_points

	if points and points.Profile ~= self.SocketProfile then
		points:SetProfile(self.SocketProfile)
	end

	self:MirrorBones(rig, host.armature, pose)
end

return META:Register()
