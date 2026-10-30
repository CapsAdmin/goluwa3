local objects = import("goluwa/objects/objects.lua")
local biped = import("lua/biped.lua")
local aim_pose = import("lua/aim_pose.lua")
local leg_pose = import("lua/leg_pose.lua")
local bone_keys = import("lua/bone_keys.lua")
local pose_variation = import("lua/pose_variation.lua")
local system = import("goluwa/system.lua")
local physics = import("goluwa/physics.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local animations = import("lua/animations.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local movesets = import("lua/movesets.lua")
local impacts = import("lua/impacts.lua")
local UNIT = import("goluwa/source_engine/units.lua").meters
local META = objects.CreateTemplate("source_pose")
local NO_RIG = {}
META:StartStorable()
META:GetSet("Profile", "creature")
META:GetSet("IdleSequence", "")
META:GetSet("WalkSequence", "")
META:GetSet("RunSequence", "")
META:IsSet("Mirror", false)
META:IsSet("OwnsArmature", false)
META:IsSet("LegIK", false)
META:GetSet("LegRig", NO_RIG)
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
local MAX_SINK = 2.5 * UNIT
local SINK_PROBE = 0.1
local SINK_FOLLOW = 20
local DOWN = Vec3(0, -1, 0)
local SINK_OPTIONS = {IncludeRigidBodies = true}
local LEG_PROBE = 0.5
local LEG_RISE = 0.35
local LEG_DROP = 0.45
local LEG_FOLLOW = 60
local PELVIS_FOLLOW = 12
local PELVIS_RISE_FOLLOW = 4
local STEP_LIFT = 0.04
local STEP_DESCEND = 0.4
local STEP_STOP = 0.15
local STEP_FLOOR_RISE = 0.02
local STEP_MAX_RATE = 4
local UP = Vec3(0, 1, 0)
local SPRINT_MAX_RATE = 1.5
local GAIT_SPEED = {
	crouch = PLAYER_WALK_SPEED * 0.6,
	walk = PLAYER_WALK_SPEED,
	run = PLAYER_RUN_SPEED,
	sprint = PLAYER_RUN_SPEED * 2,
}
local FORWARD_PARAMETERS = {move_x = 1, move_y = 0}
local DONOR_MALE = "models/humans/male_shared"
local DONOR_FEMALE = "models/humans/female_shared"
local FEMALE_MARKS = {"female", "alyx", "mossman", "chell"}
local DONOR_BIND_BONES = {
	["valvebiped.bip01_pelvis"] = true,
	["valvebiped.bip01_spine"] = true,
	["valvebiped.bip01_head1"] = true,
	["valvebiped.bip01_l_thigh"] = true,
	["valvebiped.bip01_l_calf"] = true,
	["valvebiped.bip01_l_foot"] = true,
	["valvebiped.bip01_l_upperarm"] = true,
	["valvebiped.bip01_l_forearm"] = true,
}
local SWITCH_TIME = 0.2
local ARM_BONES = {
	"clavicle_r",
	"upperarm_r",
	"forearm_r",
	"hand_r",
	"clavicle_l",
	"upperarm_l",
	"forearm_l",
	"hand_l",
}
local native_speeds = setmetatable({}, {__mode = "k"})

local function is_donor_clip(name)
	return name:starts_with("jump_holding_")
end

local function get_native_speed(clip)
	local speed = native_speeds[clip]

	if not speed then
		speed = clip:GetGroundSpeed(FORWARD_PARAMETERS)
		native_speeds[clip] = speed
	end

	return speed
end

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
	self.idle_bones = {}
	self.prev_bones = {}
	self.switch = 1
	self.grip_follow = Matrix44():Identity()
	self.grip_blend = Matrix44():Identity()
	self.leg_shift = {0, 0}
	self.leg_state = leg_pose.NewState()
	self.leg_ground = {0, 0}
	self.pelvis_ground = 0
	self.pelvis_mean = 0
	self.pelvis_rise = 0
	self.leg_normals = {Vec3(0, 1, 0), Vec3(0, 1, 0)}
	self.steps = {
		{
			height = 0,
			floor = math.huge,
			peak = 0,
			speed = 0,
			lifted = false,
			descending = false,
		},
		{
			height = 0,
			floor = math.huge,
			peak = 0,
			speed = 0,
			lifted = false,
			descending = false,
		},
	}

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

function META:GetOverride(pose, suffix, clips)
	for i = #pose.anims, 1, -1 do
		local inst = pose.anims[i]

		if inst.def.Sequence then
			local sequence = inst.def.Sequence(inst, suffix, clips)

			if sequence then return sequence, inst end
		end
	end
end

function META:SwitchSequence(animator, sequence, override)
	self.sequence = sequence
	animator:SetLoop(not override or override.def.Loop ~= false)
	animator:SetSequence(sequence)

	if override and override.def.Loop == false then animator:Restart() end
end

local function find_creature_sequence(pose, clips)
	local anims = pose.anims

	for i = #anims, 1, -1 do
		local names = anims[i].def.CreatureSequences

		if names then
			for _, name in ipairs(names) do
				if clips[name] then return name, anims[i] end
			end
		end
	end
end

local EYE_LOOK_DISTANCE = 10

function META:UpdateCreature(animator, skeleton, pose, dt)
	local reaction, inst = find_creature_sequence(pose, skeleton.ClipsByName)

	if reaction then
		if self.reaction_inst ~= inst then
			self.reaction_inst = inst
			self.sequence = reaction
			animator:SetLoop(false)
			animator:SetSequence(reaction)
			animator:Restart()
		end

		animator:SetSpeed(pose:GetTimeScale() * pose.rate_variation)
		return
	end

	self.reaction_inst = nil

	local action = pose:GetActiveAction()
	local move = action and movesets.GetMove(action)

	if move and move.Clip then
		local clip = skeleton.ClipsByName[move.Clip]

		if self.clip_actions ~= pose.Actions then
			self.clip_actions = pose.Actions
			self.sequence = move.Clip
			animator:SetLoop(move.ClipSpeed ~= nil)
			animator:SetSequence(move.Clip)
			animator:Restart()
		end

		animator:SetSpeed(
			(move.ClipSpeed or clip.Duration / pose.ActionDuration) * pose:GetTimeScale() * pose.rate_variation
		)
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

	if sequence ~= self.sequence then self:SwitchSequence(animator, sequence) end

	local clip = skeleton.ClipsByName[sequence]
	local rate = 1

	if state ~= "idle" and clip then
		local ground_speed = clip:GetGroundSpeed(params)

		if ground_speed > 0 then
			rate = math.clamp(speed / ground_speed, MIN_RATE, MAX_RATE)
		end
	end

	animator:SetSpeed(rate * pose:GetTimeScale() * pose.rate_variation)

	if clip and clip.Duration > 0 and pose:GetTimeScale() == 1 then
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

function META:AddDonorClips(skeleton)
	if skeleton.donor_checked then return end

	skeleton.donor_checked = true
	local path = self.Owner.model:GetModelPath():lower()
	local donor = DONOR_MALE

	for _, mark in ipairs(FEMALE_MARKS) do
		if path:find(mark, 1, true) then
			donor = DONOR_FEMALE

			break
		end
	end

	import("goluwa/render3d/model_decoders/mdl.lua").AddAnimations(skeleton, donor, is_donor_clip, DONOR_BIND_BONES)
end

function META:UpdatePlayer(animator, pose, dt)
	local forward_speed = pose.locomotion and pose.forward_speed or 0
	local right_speed = pose.locomotion and pose.right_speed or 0
	local speed = math.sqrt(forward_speed * forward_speed + right_speed * right_speed)
	local crouching = pose:IsCrouching() or pose.forced_crouch
	local override, sequence
	local clips = animator.skeleton.ClipsByName
	local holder = pose.Owner.weapon_holder
	local weapon = holder and holder:GetWeapon("right")
	local suffix = weapon and not weapon.weapon:IsSheathed() and weapon.weapon:GetStance() or "all"
	sequence, override = self:GetOverride(pose, suffix, clips)
	local air_crouch = crouching and pose.airborne and override and override.def.Kind == "state"
	local sprinting = not crouching and not pose.airborne and speed > PLAYER_RUN_SPEED * SPRINT_START
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

	if air_crouch then
		sequence = suffix == "all" and "cidle_all" or "cidle_" .. suffix
		override = nil
	elseif override then

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
	local native = clip and not override and get_native_speed(clip) or 0

	if native > 0 then reference = native end

	if gait == "sprint" then
		reference = math.max(reference, GAIT_SPEED.sprint / SPRINT_MAX_RATE)
	end

	if sequence ~= self.sequence then
		self:SwitchSequence(animator, sequence, override)
	end

	if speed >= 0.15 and not override and not air_crouch then
		rate = math.clamp(
			speed * pose_variation.GetStrideScale(forward_speed, right_speed, crouching) / reference,
			0.4,
			2
		)
	end

	animator:SetSpeed(
		rate * (
				override and
				override.def.Speed or
				1
			) * pose:GetTimeScale() * pose.rate_variation
	)

	if clip and clip.Duration > 0 and not override and pose:GetTimeScale() == 1 then
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

	if pose.grounded and physics.instance and not pose:GetSeat():IsValid() then
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

local FEET = {"foot_r", "foot_l"}

function META:UpdateFeet(character, pose, dt, bones, feet, soles)
	local world = self.Owner.transform:GetWorldMatrix()
	local position = character.transform:GetRenderPositionRotation() or
		character.transform:GetPosition()
	local plane = position.y - self.ground_sink
	local grounded = pose.grounded and physics.instance
	local follow = math.min(dt * LEG_FOLLOW, 1)
	local rotation = world:GetRotation():GetConjugated()
	local ground = self.leg_ground
	local mean = 0

	if not self.leg_ready then
		self.leg_ready = true
		self.pelvis_ground, self.pelvis_mean = plane, plane

		for i = 1, #feet do
			ground[i] = plane
		end
	end

	for i, name in ipairs(feet) do
		local foot = bones[name]
		local sole = soles and soles[i]
		local sx, sy, sz = foot.m30, foot.m31, foot.m32

		if sole then sx, sy, sz = foot:TransformVectorUnpacked(sole.x, sole.y, sole.z) end

		local x, y, z = world:TransformVectorUnpacked(sx, sy, sz)
		local hit = grounded and
			physics.RayCast(
				Vec3(x, y + LEG_PROBE, z),
				DOWN,
				LEG_PROBE + LEG_DROP,
				character,
				nil,
				SINK_OPTIONS
			)
		local target = grounded and ground[i] or plane
		local normal = UP

		if hit then
			target = math.clamp(hit.position.y, plane - LEG_DROP, plane + LEG_RISE)
			normal = rotation:VecMul(hit.normal or UP)
		end

		local step = self.steps[i]
		local height = sy + self.ground_sink
		local rate = math.max((height - step.height) / dt, -STEP_MAX_RATE)
		step.height = height

		if pose.airborne then
			step.lifted, step.descending, step.peak = true, true, math.huge
			step.speed = math.max(step.speed, -rate - pose.vertical_speed)
		elseif step.lifted then
			step.speed = math.max(step.speed, -rate - math.min(pose.vertical_speed, 0))
			step.peak = math.max(step.peak, height)

			if rate < -STEP_DESCEND then step.descending = true end

			if step.descending and rate > -STEP_STOP and height < (step.peak + step.floor) * 0.5 then
				if hit then impacts.FireFootstep(character, name, hit, step.speed) end

				step.lifted, step.descending, step.speed, step.floor = false, false, 0, height
			end
		elseif height > step.floor + STEP_LIFT then
			step.lifted, step.peak = true, height
		else
			step.floor = math.min(step.floor + dt * STEP_FLOOR_RISE, height)
		end

		ground[i] = ground[i] + (target - ground[i]) * follow
		local current = self.leg_normals[i]
		current:Set(
			current.x + (normal.x - current.x) * follow,
			current.y + (normal.y - current.y) * follow,
			current.z + (normal.z - current.z) * follow
		)
		self.leg_shift[i] = math.clamp(ground[i] - plane, -LEG_DROP, LEG_RISE)
		mean = mean + ground[i] / #feet
	end

	local rise = (mean - self.pelvis_mean) / dt
	self.pelvis_mean = mean
	self.pelvis_rise = self.pelvis_rise + (
			rise - self.pelvis_rise
		) * math.min(dt * PELVIS_RISE_FOLLOW, 1)
	self.pelvis_ground = self.pelvis_ground + (
			mean + self.pelvis_rise / PELVIS_FOLLOW - self.pelvis_ground
		) * math.min(dt * PELVIS_FOLLOW, 1)
	return plane
end

function META:UpdateLegs(character, pose, dt, bones)
	local plane = self:UpdateFeet(character, pose, dt, bones, FEET)
	local shift = self.leg_shift
	leg_pose.ApplyKeys(bones, pose, self.held_l and not self.held_r and -1 or 1, self.leg_state)
	leg_pose.Apply(
		bones,
		shift[1],
		shift[2],
		math.clamp(self.pelvis_ground - plane, -LEG_DROP, LEG_RISE),
		self.leg_normals,
		self.leg_state
	)
end

do
	local SEAT_ARM_BONES = {
		{"clavicle_r", "upperarm_r", "forearm_r", "hand_r"},
		{"clavicle_l", "upperarm_l", "forearm_l", "hand_l"},
	}
	local SEAT_LEG_BONES = {
		{"thigh_r", "calf_r", "foot_r"},
		{"thigh_l", "calf_l", "foot_l"},
	}
	local SIDES = {1, -1}
	local SEAT_PELVIS_HEIGHT = 0.02
	local grip_position = Vec3()
	local grip_rotation = Quat()
	local world_rotation = Quat()
	local before = {}

	for i = 1, 4 do
		before[i] = Matrix44():Identity()
	end

	local function save_chain(bones, chain, weight)
		if weight >= 0.999 then return end

		for i, name in ipairs(chain) do
			aim_pose.CopyMatrix(before[i], bones[name])
		end
	end

	local function blend_chain(bones, chain, weight)
		if weight >= 0.999 then return end

		for i, name in ipairs(chain) do
			aim_pose.BlendMatrix(bones[name], before[i], bones[name], weight)
		end
	end

	function META:ApplySeat(pose, bones, weight)
		local pelvis = bones.body
		local dx = -pelvis.m30 * weight
		local dy = (SEAT_PELVIS_HEIGHT - pelvis.m31) * weight
		local dz = -pelvis.m32 * weight

		for _, name in ipairs(aim_pose.Bones) do
			local matrix = bones[name]
			matrix.m30, matrix.m31, matrix.m32 = matrix.m30 + dx, matrix.m31 + dy, matrix.m32 + dz
		end

		-- the leg ik smoothing is stale once the character stands up again
		self.leg_ready = false
		local seat = pose:GetSeatComponent()

		if not seat then return end

		local inverse = self.Owner.transform:GetWorldMatrixInverse()
		inverse:GetRotation(world_rotation)

		for i, side in ipairs(SIDES) do
			local node = seat:GetLimbNode(side == 1 and seat.FootRight or seat.FootLeft)

			if node then
				local world = node.transform:GetWorldMatrix()
				save_chain(bones, SEAT_LEG_BONES[i], weight)
				leg_pose.SolveFoot(bones, i, inverse:TransformVectorUnpacked(world.m30, world.m31, world.m32))
				blend_chain(bones, SEAT_LEG_BONES[i], weight)
			end

			node = seat:GetLimbNode(side == 1 and seat.HandRight or seat.HandLeft)

			if node then
				local world = node.transform:GetWorldMatrix()
				grip_position:Set(inverse:TransformVectorUnpacked(world.m30, world.m31, world.m32))
				world:GetRotation(grip_rotation)
				grip_rotation:SetMul(world_rotation, grip_rotation)
				save_chain(bones, SEAT_ARM_BONES[i], weight)
				aim_pose.SolveGrip(bones, side, grip_position, grip_rotation)
				blend_chain(bones, SEAT_ARM_BONES[i], weight)
			end
		end
	end
end

do
	local function get_weapon(entity)
		return entity and entity:IsValid() and entity.weapon or nil
	end

	local function is_gone(entity)
		return entity and not entity:IsValid()
	end

	function META:MirrorBones(rig, armature, pose, dt)
		local holder = pose.Owner.weapon_holder
		local right = holder and holder:GetPosedWeapon("right") or false
		local left = holder and holder:GetPosedWeapon("left") or false
		local armed = (
				right or
				left
			)
			and
			(
				right and
				right.weapon:IsAlwaysPose() or
				left and
				left.weapon:IsAlwaysPose()
				or
				not self.sprinting and
				not pose.airborne or
				animations.PosesWeapon(pose)
			)
		local bones = self.bones
		pose.hold_wanted = armed and true or false

		if armed and (self.held_r ~= right or self.held_l ~= left) then
			if self.held_r ~= nil then
				self.prev_r, self.prev_l = self.held_r, self.held_l
				self.switch = 0
			end

			self.held_r, self.held_l = right, left
		end

		if self.prev_r ~= nil then
			self.switch = math.min(self.switch + dt / SWITCH_TIME, 1)

			if self.switch >= 1 or is_gone(self.prev_r) or is_gone(self.prev_l) then
				self.prev_r, self.prev_l = nil, nil
			end
		end

		local hold = animations.GetWeight(pose, "hold")
		local weapon_r = hold > 0.001 and get_weapon(self.held_r) or nil
		local weapon_l = hold > 0.001 and get_weapon(self.held_l) or nil
		local weapon = weapon_r or weapon_l
		local prev = weapon and self.prev_r ~= nil
		local idle = self.idle_bones
		local before = self.prev_bones

		for _, name in ipairs(aim_pose.Bones) do
			if biped.HasBone(rig, name) then rig:ClearBone(biped.SourceBones[name]) end
		end

		biped.ReadBones(rig, bones)

		if weapon and hold < 0.999 then
			for name, matrix in pairs(bones) do
				if not idle[name] then idle[name] = Matrix44():Identity() end

				aim_pose.CopyMatrix(idle[name], matrix)
			end
		end

		if prev then
			for name, matrix in pairs(bones) do
				if not before[name] then before[name] = Matrix44():Identity() end

				aim_pose.CopyMatrix(before[name], matrix)
			end
		end

		aim_pose.Apply(bones, pose, weapon_r, weapon_l)

		if prev then
			aim_pose.Apply(before, pose, get_weapon(self.prev_r), get_weapon(self.prev_l))

			for _, name in ipairs(ARM_BONES) do
				aim_pose.BlendMatrix(
					bones[name],
					before[name],
					bones[name],
					self.switch * self.switch * (3 - 2 * self.switch)
				)
			end
		end

		if weapon and hold < 0.999 then
			aim_pose.Apply(idle, pose, nil, nil)

			for _, name in ipairs(ARM_BONES) do
				aim_pose.BlendMatrix(bones[name], idle[name], bones[name], hold)
			end
		end

		for _, name in ipairs(aim_pose.Bones) do
			bones[name].m31 = bones[name].m31 - self.ground_sink
		end

		for i = 1, #pose.anims do
			local inst = pose.anims[i]
			local def = inst.def

			if def.BoneKeys then bone_keys.Apply(bones, def.BoneKeys, inst, pose) end

			if def.Bones then def.Bones(bones, inst, pose) end
		end

		if pose.legs then self:UpdateLegs(pose.Owner, pose, dt, bones) end

		local seat_weight = animations.GetWeight(pose, "seat")

		if seat_weight > 0.001 then self:ApplySeat(pose, bones, seat_weight) end

		for _, name in ipairs(aim_pose.Bones) do
			if biped.HasBone(rig, name) then
				rig:SetBone(biped.SourceBones[name], bones[name], "model")
			end
		end

		for name in pairs(biped.SourceBones) do
			local matrix = bones[name]

			if name == "hand_r" or name == "hand_l" then
				local is_right = name == "hand_r"

				if weapon then
					local follow = (right or left) and aim_pose.GetFollowGripMatrix(matrix, is_right) or matrix
					aim_pose.CopyMatrix(self.grip_follow, follow)
					local gripped = aim_pose.GetGripMatrix(
						matrix,
						aim_pose.GetGripAim(
							pose,
							aim_pose.GetHoldAim(pose, aim_pose.GetAim(pose, pose.aim)),
							is_right and 1 or -1
						)
					)

					if hold < 0.999 then
						aim_pose.BlendMatrix(self.grip_blend, self.grip_follow, gripped, hold)
						gripped = self.grip_blend
					end

					matrix = gripped
				elseif right or left then
					matrix = aim_pose.GetFollowGripMatrix(matrix, is_right)
				end
			end

			armature:SetBone(name, matrix, "model")
		end

		-- reading the pure animation above left the skin matrices without the overrides, and the skin is read after every update
		rig:Compute()
	end
end

function META:UpdateCreatureLimbs(rig, pose, dt)
	local definition = self.LegRig
	local limbs = self.limbs
	local bones = self.bones
	local root = definition.Root
	local ragdoll = self.character.source_ragdoll

	if not limbs then
		limbs = {}
		self.limbs = limbs
		self.limb_feet = {}
		self.leg_shift, self.leg_ground, self.leg_normals, self.steps = {}, {}, {}, {}

		for i, chain in ipairs(definition.Legs) do
			limbs[i] = leg_pose.NewLimb(chain[1], chain[2], chain[3])
			self.limb_feet[i] = chain[3]
			self.leg_shift[i] = 0
			self.leg_ground[i] = 0
			self.leg_normals[i] = Vec3(0, 1, 0)
			self.steps[i] = {
				height = 0,
				floor = math.huge,
				peak = 0,
				speed = 0,
				lifted = false,
				descending = false,
			}
		end

		self.leg_ready = false
		self.limb_targets = {}

		for i = 1, #limbs do
			self.limb_targets[i] = {x = 0, y = 0, z = 0}
		end
	end

	rig:ClearBone(root)

	for _, limb in ipairs(limbs) do
		for _, name in ipairs(limb.chain) do
			rig:ClearBone(name)
		end
	end

	if ragdoll and ragdoll:IsDead() then return end

	if not self.soles then
		if not self.soles_loading then
			self.soles_loading = true
			model_loader.LoadModel(self.Owner.model.ModelPath, function(data)
				self.soles = leg_pose.GetSoles(data.physics.ragdoll, self.limb_feet)
			end)
		end

		return
	end

	bones[root] = rig:GetBone(root)

	for _, limb in ipairs(limbs) do
		for _, name in ipairs(limb.chain) do
			bones[name] = rig:GetBone(name)
		end
	end

	self:UpdateGroundSink(self.character, pose, dt)
	bones[root].m31 = bones[root].m31 - self.ground_sink

	for _, limb in ipairs(limbs) do
		for _, name in ipairs(limb.chain) do
			bones[name].m31 = bones[name].m31 - self.ground_sink
		end
	end

	local plane = self:UpdateFeet(pose.Owner, pose, dt, bones, self.limb_feet, self.soles)
	local body_shift = math.clamp(self.pelvis_ground - plane, -LEG_DROP, LEG_RISE)

	for i, limb in ipairs(limbs) do
		local tip = bones[limb.foot]
		local target = self.limb_targets[i]
		target.x, target.y, target.z = tip.m30, tip.m31 + self.leg_shift[i], tip.m32
	end

	bones[root].m31 = bones[root].m31 + body_shift

	for _, limb in ipairs(limbs) do
		for _, name in ipairs(limb.chain) do
			bones[name].m31 = bones[name].m31 + body_shift
		end
	end

	for i, limb in ipairs(limbs) do
		local target = self.limb_targets[i]
		leg_pose.SolveLimb(bones, limb, target.x, target.y, target.z, self.leg_normals[i])
	end

	rig:SetBone(root, bones[root], "model")

	for _, limb in ipairs(limbs) do
		for _, name in ipairs(limb.chain) do
			rig:SetBone(name, bones[name], "model")
		end
	end

	rig:Compute()
end

function META:UpdateCreatureLegs(rig, pose, dt)
	local bones = self.bones
	local ragdoll = self.character.source_ragdoll

	for _, name in ipairs(aim_pose.Bones) do
		if biped.HasBone(rig, name) then rig:ClearBone(biped.SourceBones[name]) end
	end

	if ragdoll and ragdoll:IsDead() then return end

	biped.ReadBones(rig, bones)
	self:UpdateGroundSink(self.character, pose, dt)

	for _, name in ipairs(aim_pose.Bones) do
		bones[name].m31 = bones[name].m31 - self.ground_sink
	end

	if pose.legs then self:UpdateLegs(pose.Owner, pose, dt, bones) end

	for _, name in ipairs(aim_pose.Bones) do
		if biped.HasBone(rig, name) then
			rig:SetBone(biped.SourceBones[name], bones[name], "model")
		end
	end

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
		self:AddDonorClips(animator.skeleton)
		self:UpdatePlayer(animator, pose, dt)
		local character = self.character
		owner.eyes:SetLookTarget(
			character.transform:GetPosition() + character.character_movement:GetViewOffset() + pose.aim_rotation:GetForward() * EYE_LOOK_DISTANCE
		)
	else
		self:UpdateCreature(animator, animator.skeleton, pose, dt)

		if self.LegIK and not host then self:UpdateCreatureLegs(rig, pose, dt) end

		if self.LegRig.Root then self:UpdateCreatureLimbs(rig, pose, dt) end
	end

	if host then
		local points = host.attachment_points

		if points and points.Profile ~= self.SocketProfile then
			points:SetProfile(self.SocketProfile)
		end

		self:UpdateGroundSink(self.character, pose, dt)
		self:MirrorBones(rig, host.armature, pose, dt)
	end

	if ragdoll and ragdoll:HasLimp() then
		ragdoll:DriveRig(rig, host and host.armature)
	end
end

return META:Register()
