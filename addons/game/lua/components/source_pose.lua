local objects = import("goluwa/objects/objects.lua")
local biped = import("lua/biped.lua")
local aim_pose = import("lua/aim_pose.lua")
local pose_variation = import("lua/pose_variation.lua")
local system = import("goluwa/system.lua")
local physics = import("goluwa/physics.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local UNIT = import("goluwa/source_engine/units.lua").meters
local META = objects.CreateTemplate("source_pose")
META:StartStorable()
META:GetSet("Profile", "creature")
META:GetSet("IdleSequence", "")
META:GetSet("WalkSequence", "")
META:GetSet("RunSequence", "")
META:GetSet("AttackSequence", "")
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
local SPRINT_START = 1.5
local AIR_SPEED = 0.8
local MAX_SINK = 2.5 * UNIT
local SINK_PROBE = 0.1
local SINK_FOLLOW = 20
local DOWN = Vec3(0, -1, 0)
local SINK_OPTIONS = {IncludeRigidBodies = true}
local SPRINT_MAX_RATE = 1.5
local GAIT_SPEED = {
	crouch = PLAYER_WALK_SPEED * 0.6,
	walk = PLAYER_WALK_SPEED,
	run = PLAYER_RUN_SPEED,
	sprint = PLAYER_RUN_SPEED * 2,
}
local FORWARD_PARAMETERS = {move_x = 1, move_y = 0}
local native_speeds = setmetatable({}, {__mode = "k"})

local function get_native_speed(clip)
	local speed = native_speeds[clip]

	if not speed then
		speed = clip:GetGroundSpeed(FORWARD_PARAMETERS)
		native_speeds[clip] = speed
	end

	return speed
end

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
	self.ground_sink = 0

	if RENDER_3D and self.OwnsArmature then
		self.Owner:EnsureComponent("armature", {Skeleton = biped.SkeletonName})
	end

	self:AddGlobalEvent("Update")
end

function META:OnRemove()
	if self.character and self.character:IsValid() then
		local pose = self.character.character_pose

		if pose then pose.driver = nil end
	end
end

local function find_ancestor(entity, component)
	local node = entity

	while node:IsValid() do
		if node[component] then return node end

		node = node:GetParent()
	end
end

function META:UpdateCreature(animator, skeleton, pose, dt)
	if pose.action == "attack" and self.AttackSequence ~= "" then
		if self.attack_actions ~= pose.Actions then
			self.attack_actions = pose.Actions
			self.sequence = self.AttackSequence
			animator:SetLoop(false)
			animator:SetSequence(self.AttackSequence)
			animator:Restart()
		end

		animator:SetSpeed(pose.animation_speed * pose.rate_variation)
		return
	end

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
		animator:SetLoop(true)
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

	animator:SetSpeed(rate * pose.animation_speed * pose.rate_variation)

	if clip and clip.Duration > 0 and pose.animation_speed == 1 then
		local ground_speed = clip:GetGroundSpeed(params)

		if state == "idle" then
			animator:SyncCycle(
				pose_variation.GetClockCycle(pose.seed, pose.rate_scale, system.GetGameTime(), clip.Duration),
				dt
			)
		elseif ground_speed > 0 then
			animator:SyncCycle(
				pose_variation.GetStrideCycle(pose.seed, pose.rate_scale, pose.Distance, ground_speed * clip.Duration),
				dt
			)
		end
	end

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
	local air = not pose.grounded and
		(
			self.airborne or
			math.abs(pose.vertical_speed) > AIR_SPEED
		)
	self.airborne = air
	local holder = pose.Owner.weapon_holder
	local weapon = holder and holder:GetActiveWeapon()
	local suffix = weapon and WEAPON_SUFFIX[weapon.prefab.Path] or "all"
	local sequence
	local sprinting = not crouching and not air and speed > PLAYER_RUN_SPEED * SPRINT_START
	self.sprinting = sprinting
	local gait = crouching and
		"crouch" or
		(
			sprinting and
			"sprint" or
			(
				speed > PLAYER_WALK_SPEED * 1.4 and
				"run" or
				"walk"
			)
		)
	local rate = 1

	if air then
		sequence = "jump_" .. (suffix == "all" and "passive" or suffix)
	elseif speed < 0.15 then
		sequence = (crouching and "cidle_" or "idle_") .. suffix

		if suffix == "all" then
			sequence = crouching and "cidle_all" or "idle_all_01"
		end
	elseif gait == "crouch" then
		sequence = "cwalk_" .. suffix
	elseif gait == "sprint" then
		sequence = "run_all_02"
	elseif gait == "run" then
		sequence = suffix == "all" and "run_all_01" or "run_" .. suffix
	else
		sequence = "walk_" .. suffix
	end

	local clip = animator.skeleton.ClipsByName[sequence]
	local reference = GAIT_SPEED[gait]
	local native = clip and not air and get_native_speed(clip) or 0

	if native > 0 then reference = native end

	if gait == "sprint" then
		reference = math.max(reference, GAIT_SPEED.sprint / SPRINT_MAX_RATE)
	end

	if sequence ~= self.sequence then
		self.sequence = sequence
		animator:SetLoop(not air)
		animator:SetSequence(sequence)

		if air then animator:Restart() end
	end

	if speed >= 0.15 and not air then
		rate = math.clamp(
			speed * pose_variation.GetStrideScale(forward_speed, right_speed, crouching) / reference,
			0.4,
			2
		)
	end

	animator:SetSpeed(rate * pose.animation_speed * pose.rate_variation)

	if clip and clip.Duration > 0 and not air and pose.animation_speed == 1 then
		if speed < 0.15 then
			animator:SyncCycle(
				pose_variation.GetClockCycle(pose.seed, pose.rate_scale, system.GetGameTime(), clip.Duration),
				dt
			)
		else
			animator:SyncCycle(
				pose_variation.GetStrideCycle(pose.seed, pose.rate_scale, pose.Distance, reference * clip.Duration),
				dt
			)
		end
	end

	local follow = math.min(dt * 10, 1)
	self.move_x = self.move_x + (forward_speed / reference - self.move_x) * follow
	self.move_y = self.move_y + (right_speed / reference - self.move_y) * follow
	animator:SetPoseParameterByName("move_x", math.clamp(self.move_x, -1, 1))
	animator:SetPoseParameterByName("move_y", math.clamp(self.move_y, -1, 1))
	animator:SetPoseParameterByName("vertical_velocity", math.clamp(pose.vertical_speed / 4, -1, 1))
end

function META:UpdateGroundSink(character, pose, dt)
	local target = 0

	if pose.grounded and physics.instance then
		local transform = character.transform
		local position = transform:GetRenderPositionRotation() or transform:GetPosition()
		local hit = physics.RayCast(
			Vec3(position.x, position.y + SINK_PROBE, position.z),
			DOWN,
			SINK_PROBE + MAX_SINK * 2,
			character,
			nil,
			SINK_OPTIONS
		)

		if hit then target = math.clamp(position.y - hit.position.y, 0, MAX_SINK) end
	end

	self.ground_sink = self.ground_sink + (target - self.ground_sink) * math.min(dt * SINK_FOLLOW, 1)
end

function META:MirrorBones(rig, armature, pose)
	local holder = pose.Owner.weapon_holder
	local active = holder and holder:GetPosedWeapon()
	local armed = active ~= nil and
		(
			active.weapon:IsAlwaysPose() or
			not self.sprinting and
			not self.airborne
		)
	local bones = self.bones

	for _, name in ipairs(aim_pose.Bones) do
		if biped.HasBone(rig, name) then rig:ClearBone(biped.SourceBones[name]) end
	end

	biped.ReadBones(rig, bones)
	aim_pose.Apply(bones, pose, armed and active.weapon or nil)

	for _, name in ipairs(aim_pose.Bones) do
		bones[name].m31 = bones[name].m31 - self.ground_sink
	end

	for _, name in ipairs(aim_pose.Bones) do
		if biped.HasBone(rig, name) then
			rig:SetBone(biped.SourceBones[name], bones[name], "model")
		end
	end

	for name in pairs(biped.SourceBones) do
		local matrix = bones[name]

		if armed and (name == "hand_r" or name == "hand_l") then
			matrix = aim_pose.GetGripMatrix(matrix, aim_pose.GetAim(pose))
		elseif active and (name == "hand_r" or name == "hand_l") then
			matrix = aim_pose.GetFollowGripMatrix(matrix, name == "hand_r")
		end

		armature:SetBone(name, matrix, "model")
	end

	-- reading the pure animation above left the skin matrices without the overrides, and the skin is read after every update
	rig:Compute()
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
	local ragdoll = self.character.ragdoll
	local host = self.Mirror and find_ancestor(owner, "armature")

	if ragdoll and ragdoll.driven_rig then ragdoll:ClearRig() end

	if self.Profile == "gmod_player" then
		self:UpdatePlayer(animator, pose, dt)
	else
		self:UpdateCreature(animator, animator.skeleton, pose, dt)
	end

	if host then
		local points = host.attachment_points

		if points and points.Profile ~= self.SocketProfile then
			points:SetProfile(self.SocketProfile)
		end

		self:UpdateGroundSink(self.character, pose, dt)
		self:MirrorBones(rig, host.armature, pose)
	end

	if ragdoll and ragdoll:HasLimp() then
		ragdoll:DriveRig(rig, host and host.armature)
	end
end

return META:Register()
