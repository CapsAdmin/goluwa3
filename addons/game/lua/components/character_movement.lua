local objects = import("goluwa/objects/objects.lua")
local system = import("goluwa/system.lua")
local steam = import("goluwa/steam/steam.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local event = import("goluwa/event.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local network = import("goluwa/network/network.lua")
local Entity = import("goluwa/entities/entity.lua")
local damage = import("lua/damage.lua")
local pose_variation = import("lua/pose_variation.lua")
local META = objects.CreateTemplate("character_movement")
local UNIT = import("goluwa/source_engine/units.lua").meters
META:IsSet("Crouching", false)
META:GetSet("GroundSpeed", 200 * UNIT)
META:GetSet("AirSpeed", 30 * UNIT)
META:GetSet("Acceleration", 10)
META:GetSet("AirAcceleration", 10)
META:GetSet("Friction", 6)
META:GetSet("StopSpeed", 100 * UNIT)
META:GetSet("JumpSpeed", 196.75 * UNIT)
META:GetSet("Gravity", 600 * UNIT)
META:GetSet("StepHeight", 18 * UNIT)
META:GetSet("GroundReach", 2 * UNIT)
META:IsSet("StickToGround", true)
META:GetSet("LeaveGroundSpeed", 250 * UNIT)
META:GetSet("MinGroundNormalY", 0.7)
META:GetSet("Radius", 16 * UNIT)
META:GetSet("Height", 72 * UNIT)
META:GetSet("EyeHeight", 64 * UNIT)
META:GetSet("CrouchHeight", 36 * UNIT)
META:GetSet("CrouchEyeHeight", 28 * UNIT)
META:GetSet("CrouchTransitionTime", 0.05)
META:GetSet("FlySpeed", 30)
META:GetSet("FlySpeedRamp", 1)
META:GetSet("FlyAccelerate", 4)
META:GetSet("FlyBrake", 5)
META:GetSet("FlySpeedMaxMultiplier", 500)
META:GetSet("WalkMaxLinearSpeed", 240)
META:GetSet("SprintMultiplier", 2)
META:GetSet("CrouchMultiplier", 1 / 3)
META:GetSet("RollSpeed", 220 * UNIT)
META:GetSet("WalkMultiplier", 0.5)
META:GetSet("SuperMultiplier", 3)
META:GetSet("Mode", "fly")
META:GetSet("SwimSpeed", 3)
META:GetSet("SwimSprintMultiplier", 1.6)
META:GetSet("SwimAcceleration", 30)
META:GetSet("SwimEnterFraction", 0.75)
META:GetSet("SwimExitFraction", 0.5)
META:IsSet("Swimming", false)
META:GetSet("BodyDensity", 1060)
META:GetSet("SafeFallSpeed", 7)
META:GetSet("FatalFallSpeed", 20)
META:GetSet("RespawnDelay", 1)
META:GetSet("DeadFriction", 0.5)
META:GetSet("DeadRollingFriction", 8)
META:GetSet("DeadTipSpeed", 1.2)
local ROLL_ENTRY = 0.9
local ROLL_HOLD = 0.5
local ROLL_DECAY = 0.6
local ROLL_EXIT = 0.25
local ROLL_FLOOR = 0.3

local function classify_roll(direction, rotation)
	local forward = rotation:GetForward()
	local right = rotation:GetRight()
	local f = direction.x * forward.x + direction.z * forward.z
	local r = direction.x * right.x + direction.z * right.z

	if math.abs(f) >= math.abs(r) then return f >= 0 and "forward" or "back" end

	return r >= 0 and "right" or "left"
end

function META:IsRolling()
	return self.roll ~= nil and not self.roll.leaving
end

function META:Lunge(direction, distance, delay, duration)
	self.lunge = {
		direction = direction:Copy(),
		distance = distance,
		delay = delay,
		time = duration,
		elapsed = 0,
	}
end

function META:GetRollKind()
	return self:IsRolling() and self.roll.kind or nil
end

function META:Initialize()
	self.Owner:EnsureComponent("transform")
	self.Owner:EnsureComponent("rigid_body")
	assert(self.Owner.rigid_body)
	self.crouch_alpha = self:IsCrouching() and 1 or 0
	self.distance = 0
	self.previous_velocity = Vec3()
	self.previous_valid = false
	self.dead = false
	self.flat_ground_time = 0
	self.step_hold_time = 0
	self.fly_speed_multiplier = 1
	self.Owner.transform.RenderOffset = Vec3()
	self:AddGlobalEvent("PhysicsUpdate")
	self:AddGlobalEvent("Update")
	self.mode = nil
	self:ApplyMode(self.Mode)
end

local controller_names = {}

function META.RegisterController(name)
	table.insert(controller_names, name)
end

function META:GetController()
	local owner = self.Owner

	for _, name in ipairs(controller_names) do
		local controller = owner[name]

		if controller then return controller end
	end

	error("character has no controller: " .. tostring(owner), 2)
end

function META:GetCommand()
	return self:GetController().cmd
end

function META:TeleportTo(position)
	local body = self.Owner.rigid_body
	self:MoveBodyBy(body, position - body:GetOriginPosition())
	body:SetVelocity(Vec3())
	self.previous_valid = false
end

function META:Reset(mode)
	self.mode = nil
	self.dead = false
	self.previous_valid = false
	self.Crouching = false
	self.crouch_alpha = 0
	self.CrouchTransition = false
	self.CrouchAnchorMode = nil
	self.CrouchAnchorPosition = nil
	self.was_grounded = false
	self.flat_ground_time = 0
	self.step_hold_time = 0
	self.jumping = false
	self.roll = nil
	self.Swimming = false
	self.ground_x = nil
	self.ground_z = nil
	self.ground_body = nil
	self.jump_requested = nil
	self.fly_speed_multiplier = 1
	self.Owner.transform.RenderOffset:Set(0, 0, 0)
	self:InvalidateBodyGeometry()
	self:ApplyMode(mode)
	self.Owner:CallLocalEvent("OnCharacterReset")
end

function META:GetGrounded()
	return self.was_grounded == true and not self.dead
end

function META:GetGroundYawVelocity()
	local carrier = self.ground_body

	if carrier and carrier:IsValid() then return carrier.AngularVelocity.y end

	return 0
end

function META:GetEyeOffset()
	local _, _, eye_height = self:GetDimensions()
	return Vec3(0, eye_height, 0)
end

function META:ClampHeadOffset(head)
	local limit = self.Radius * 2
	local length = head:GetLength()

	if length > limit then return head * (limit / length) end

	return head:Copy()
end

function META:GetHeadOffset()
	return self:ClampHeadOffset(self:GetCommand().head)
end

function META:GetViewOffset()
	return self:GetEyeOffset() + self:GetHeadOffset()
end

function META:SetEyePosition(position)
	self.Owner.transform:SetPosition(position - self:GetEyeOffset())
end

function META:GetDimensions(alpha)
	alpha = alpha == nil and (self.crouch_alpha or (self:IsCrouching() and 1 or 0)) or alpha
	return self.Radius,
	math.lerp(alpha, self.Height, self.CrouchHeight),
	math.lerp(alpha, self.EyeHeight, self.CrouchEyeHeight)
end

function META:InvalidateBodyGeometry()
	local body = self.Owner.rigid_body

	if not body then return end

	for _, collider in ipairs(body:GetColliders()) do
		collider:InvalidateGeometry()
	end

	body.CollisionLocalPoints = nil
	body.SupportLocalPoints = nil
	body.LocalBounds = nil
	body.BuoyancyCells = nil
	body:RefreshMassProperties()

	if body.SetAwake then body:SetAwake(true) end
end

function META:ApplyCrouchAlpha(alpha)
	local body = self.Owner.rigid_body

	if not body then return end

	self.crouch_alpha = alpha
	local radius, height = self:GetDimensions(alpha)
	local shape = body:GetPhysicsShape()
	local feet = body:GetOriginPosition():Copy()

	if shape and shape.GetTypeName and shape:GetTypeName() == "capsule" then
		shape:SetRadius(radius)
		shape:SetHeight(height)
		self:InvalidateBodyGeometry()
	end

	if self.CrouchAnchorMode and self.CrouchAnchorPosition then
		if self.CrouchAnchorMode == "feet" then
			feet = self.CrouchAnchorPosition:Copy()
		else
			feet = self.CrouchAnchorPosition - Vec3(0, height, 0)
		end
	end

	local velocity = body:GetVelocity():Copy()
	local angular_velocity = body:GetAngularVelocity():Copy()
	body:SetCenterOffset(Vec3(0, height * 0.5, 0))
	self.Owner.transform:SetPosition(feet)
	body:SynchronizeFromTransform()
	body.PreviousPosition = body.Position:Copy()
	body:SetVelocity(velocity)
	body:SetAngularVelocity(angular_velocity)
end

function META:UpdateCrouchTransition(dt)
	if not self.CrouchTransition then return end

	self.CrouchTransitionElapsed = math.min((self.CrouchTransitionElapsed or 0) + dt, self.CrouchTransitionTime)
	local duration = math.max(self.CrouchTransitionTime, 0.001)
	local frac = math.min(1, self.CrouchTransitionElapsed / duration)
	local alpha = math.lerp(frac, self.CrouchTransitionStartAlpha, self.CrouchTransitionTargetAlpha)
	self:ApplyCrouchAlpha(alpha)

	if frac >= 1 then
		self.CrouchTransition = false
		self.CrouchAnchorMode = nil
		self.CrouchAnchorPosition = nil
		self.CrouchTransitionStartAlpha = nil
		self.CrouchTransitionTargetAlpha = nil
		self.CrouchTransitionElapsed = nil
	end
end

function META:ResetBodyRotation()
	local body = self.Owner.rigid_body

	if not body then return end

	local rotation = Quat():Identity()
	self.Owner.transform:SetRotation(rotation)
	body:SetRotation(rotation)
	body.PreviousRotation = rotation:Copy()
	body:SetAngularVelocity(Vec3())
end

local UP = Vec3(0, 1, 0)
local DOWN = Vec3(0, -1, 0)
local GROUND_RAY_OPTIONS = {IncludeRigidBodies = true, IgnoreKinematicBodies = false}

function META:SetBodyYaw(view)
	local body = self.Owner.rigid_body
	local forward = view:GetForward()
	local yaw = QuatFromAxis(math.atan2(-forward.x, -forward.z), UP)
	local current = body:GetRotation()

	if
		math.abs(current.x - yaw.x) + math.abs(current.y - yaw.y) + math.abs(current.z - yaw.z) + math.abs(current.w - yaw.w) < 1e-7
	then
		return
	end

	self.Owner.transform:SetRotation(yaw:Copy())
	self.Owner.transform.InterpolatedFrame = nil
	body:SetRotation(yaw)
	body.PreviousRotation = yaw:Copy()
	body.StepStartRotation:CopyFrom(yaw)
	body:SetAngularVelocity(Vec3())
end

local MOVE = {
	velocity = Vec3(),
	position = Vec3(),
	move = Vec3(),
	wish_speed = 0,
	grounded = false,
	jump_pressed = false,
	jump_down = false,
	pitch = 0,
	dt = 0,
}
local STEP_PROBE_LIFT = 0.04
local STEP_REACH_MARGIN = 0.03
local STEP_IMMINENT_MARGIN = 0.08
local STEP_PROBE_BACKOFF = 0.05
local STEP_MIN_GAIN = 0.005
local STEP_MIN_RISE = 0.002
local STEP_LOW_PROBE_EXTRA = 0.15
local STEP_LANDING_MARGIN = 0.02
local GROUND_RAY_LIFT = 0.02
local FLAT_GROUND_NORMAL_Y = 0.98
local FLAT_GROUND_MEMORY = 0.15
local STEP_HOLD_TIME = 0.12
local STEP_SMOOTH_SPEED = 8
local STEP_SMOOTH_MIN_SPEED = 1
local STEP_OPTIONS = {Rotation = nil, IgnoreRigidBodies = false, IgnoreKinematicBodies = false}

local function ignore_ragdoll_parts(owner)
	return owner.ragdoll_part == nil
end

local CARRY = Vec3()

local function get_carry_velocity(carrier, point, dt)
	local velocity = carrier.Velocity
	local angular = carrier.AngularVelocity
	local speed = angular:GetLength()

	if speed < 0.0001 then
		CARRY:CopyFrom(velocity)
		return CARRY
	end

	local center = carrier.Position
	local rx, ry, rz = point.x - center.x, point.y - center.y, point.z - center.z
	local kx, ky, kz = angular.x / speed, angular.y / speed, angular.z / speed
	local cos, sin = math.cos(speed * dt), math.sin(speed * dt)
	local dot = (kx * rx + ky * ry + kz * rz) * (1 - cos)
	local cx, cy, cz = ky * rz - kz * ry, kz * rx - kx * rz, kx * ry - ky * rx
	CARRY:Set(
		velocity.x + (rx * (cos - 1) + cx * sin + kx * dot) / dt,
		velocity.y + (ry * (cos - 1) + cy * sin + ky * dot) / dt,
		velocity.z + (rz * (cos - 1) + cz * sin + kz * dot) / dt
	)
	return CARRY
end

function META:MoveBodyBy(body, offset)
	local velocity = body:GetVelocity():Copy()
	self.Owner.transform:SetPosition(body:GetOriginPosition() + offset)
	body:SynchronizeFromTransform()
	body.PreviousPosition = body.Position:Copy()
	body:SetVelocity(velocity)
end

function META:TryStepUp(direction, distance)
	local body = self.Owner.rigid_body
	local physics = body:GetPhysics()
	local collider = body:GetColliders()[1]
	local owner = self.Owner
	local filter = body:GetFilterFunction()
	local position = body:GetPosition()
	STEP_OPTIONS.Rotation = body:GetRotation()
	local gap = body:GetCollisionMargin() * 2
	local start = position + Vec3(0, STEP_PROBE_LIFT, 0) - direction * STEP_PROBE_BACKOFF
	local reach_length = STEP_PROBE_BACKOFF + self.Radius + STEP_REACH_MARGIN + distance
	local flat = physics.SweepCollider(collider, start, direction * reach_length, owner, filter, STEP_OPTIONS)
	local flat_distance

	if flat then
		if flat.normal.y >= self.MinGroundNormalY then return false end

		flat_distance = reach_length * flat.fraction
	else
		local low_length = reach_length + STEP_LOW_PROBE_EXTRA
		local low = physics.SweepCollider(
			collider,
			position - direction * STEP_PROBE_BACKOFF,
			direction * low_length,
			owner,
			filter,
			STEP_OPTIONS
		)

		if not low or low.normal.y >= self.MinGroundNormalY then return false end

		flat_distance = low_length * low.fraction
	end

	if flat_distance - STEP_PROBE_BACKOFF > distance * 2 + STEP_IMMINENT_MARGIN then
		return false
	end

	local up = Vec3(0, self.StepHeight + gap - STEP_PROBE_LIFT, 0)
	local up_hit = physics.SweepCollider(collider, start, up, owner, filter, STEP_OPTIONS)
	local raised = start + up * (up_hit and up_hit.fraction or 1)
	local across_length = flat_distance + self.Radius + STEP_LANDING_MARGIN
	local across = physics.SweepCollider(collider, raised, direction * across_length, owner, filter, STEP_OPTIONS)
	local across_distance = across_length * (across and across.fraction or 1)

	if across_distance <= flat_distance + STEP_MIN_GAIN then return false end

	local drop = Vec3(0, -(self.StepHeight + gap + STEP_PROBE_LIFT), 0)

	for i = 1, 2 do
		local landing_distance = math.min(
			flat_distance + (
					i == 1 and
					self.Radius + STEP_LANDING_MARGIN or
					self.Radius * 0.5
				),
			across_distance
		)
		local landing = raised + direction * landing_distance
		local down = physics.SweepCollider(collider, landing, drop, owner, filter, STEP_OPTIONS)

		if down and down.normal.y >= self.MinGroundNormalY then
			local lift = landing.y + drop.y * down.fraction + gap - position.y

			if lift - gap > STEP_MIN_RISE and lift <= self.StepHeight + gap + STEP_MIN_GAIN then
				self:MoveBodyBy(body, Vec3(0, lift, 0))
				self.Owner.transform.RenderOffset.y = self.Owner.transform.RenderOffset.y - lift
				self.step_hold_time = STEP_HOLD_TIME
				return true
			end
		end
	end

	return false
end

function META:SweepHull(direction, length)
	local body = self.Owner.rigid_body
	STEP_OPTIONS.Rotation = body:GetRotation()
	return body:GetPhysics().SweepCollider(
		body:GetColliders()[1],
		body:GetPosition(),
		direction * length,
		self.Owner,
		body:GetFilterFunction(),
		STEP_OPTIONS
	)
end

function META:CanStand()
	local body = self.Owner.rigid_body
	local _, current_height = self:GetDimensions()
	local extra = self.Height - current_height

	if extra <= 0.001 then return true end

	STEP_OPTIONS.Rotation = body:GetRotation()
	return not body:GetPhysics().SweepCollider(
		body:GetColliders()[1],
		body:GetPosition(),
		Vec3(0, extra, 0),
		self.Owner,
		body:GetFilterFunction(),
		STEP_OPTIONS
	)
end

function META:FindGround(reach)
	local body = self.Owner.rigid_body
	local physics = body:GetPhysics()
	STEP_OPTIONS.Rotation = body:GetRotation()
	local resting_gap = body:GetCollisionMargin() * 2
	local sweep_length = reach + resting_gap
	local drop = Vec3(0, -sweep_length, 0)
	local hit = physics.SweepCollider(
		body:GetColliders()[1],
		body:GetPosition(),
		drop,
		self.Owner,
		body:GetFilterFunction(),
		STEP_OPTIONS
	)
	local _, height = self:GetDimensions()
	local origin = body:GetPosition() - Vec3(0, height * 0.5 - GROUND_RAY_LIFT, 0)
	local ray = physics.RayCast(
		origin,
		DOWN,
		sweep_length + GROUND_RAY_LIFT,
		self.Owner,
		body:GetFilterFunction(),
		GROUND_RAY_OPTIONS
	)

	if hit and hit.normal.y >= self.MinGroundNormalY then
		local ground_distance = sweep_length * hit.fraction
		local normal = hit.normal

		if not ray then
			normal = UP
		elseif ray.normal.y >= self.MinGroundNormalY then
			local rolled = self.Radius * (1 / ray.normal.y - 1) + GROUND_RAY_LIFT
			normal = ray.distance - GROUND_RAY_LIFT <= ground_distance + rolled and ray.normal or UP
		end

		return true, math.max(ground_distance - resting_gap, 0), normal, hit.rigid_body
	end

	if not ray or ray.normal.y < self.MinGroundNormalY then return false end

	return true,
	math.max(ray.distance - GROUND_RAY_LIFT - resting_gap, 0),
	ray.normal,
	ray.rigid_body
end

function META:SetCrouch(b)
	local body = self.Owner.rigid_body

	if not body then return end

	if self:IsCrouching() == b then return end

	local _, current_height = self:GetDimensions()
	local feet = body:GetOriginPosition():Copy()
	self.CrouchTransition = true
	self.CrouchTransitionElapsed = 0
	self.CrouchTransitionStartAlpha = self.crouch_alpha or (self:IsCrouching() and 1 or 0)
	self.CrouchTransitionTargetAlpha = b and 1 or 0

	if body:GetGrounded() then
		self.CrouchAnchorMode = "feet"
		self.CrouchAnchorPosition = feet
	else
		self.CrouchAnchorMode = "head"
		self.CrouchAnchorPosition = feet + Vec3(0, current_height, 0)
	end

	self.Crouching = b
end

do
	local UP = Vec3(0, 1, 0)

	function META:Die()
		local body = self.Owner.rigid_body
		self.ground_body = nil
		local velocity = body:GetVelocity()
		local direction = Vec3(velocity.x, 0, velocity.z)

		if direction:GetLength() < 0.5 then
			local angle = math.random() * math.pi * 2
			direction = Vec3(math.cos(angle), 0, math.sin(angle))
		else
			direction = direction:GetNormalized()
		end

		self.dead = true
		self.death_time = system.GetElapsedTime()
		self.Swimming = false

		if self.Owner.ragdoll then
			body:SetCollisionEnabled(false)
			body:SetMotionType("kinematic")
			return
		end

		body:SetCollisionEnabled(true)
		body:SetGravityScale(self.Gravity / body:GetPhysics().Gravity:GetLength())
		body:SetLockRotation(false)
		body:SetGroundedSettling(true)
		body:SetFriction(self.DeadFriction)
		body:SetRollingFriction(self.DeadRollingFriction)
		body:SetRollingFrictionCombineMode("max")
		body:SetAngularVelocity(UP:GetCross(direction) * self.DeadTipSpeed)
	end

	function META:Impact(speed)
		local owner = self.Owner
		local health = owner.health

		if not health or speed <= self.SafeFallSpeed or not network.HasAuthority() then
			return
		end

		local safe = self.SafeFallSpeed
		local fatal = self.FatalFallSpeed
		damage.Deal(
			owner,
			{
				Attacker = owner,
				Inflictor = Entity.World,
				Damage = health:GetMaxHealth() * (
						speed * speed - safe * safe
					) / (
						fatal * fatal - safe * safe
					),
				Position = owner.transform:GetPosition(),
				Normal = UP,
				Force = Vec3(0, -speed, 0),
			}
		)
	end
end

function META:ApplyMode(mode)
	local body = self.Owner.rigid_body
	self.mode = mode
	self.ground_body = nil
	self.previous_valid = false
	self.Swimming = false
	self.Mode = mode

	if not body then return end

	local radius, height = self:GetDimensions()
	local position = self.Owner.transform:GetPosition():Copy()
	body:SetMotionType("dynamic")
	body:SetShape(CapsuleShape.New(radius, height))
	body:SetCenterOffset(Vec3(0, height * 0.5, 0))
	body:SetCCD(true)
	body:SetCanSleep(false)
	body:SetLinearDamping(0)
	body:SetAirLinearDamping(0)
	body:SetAngularDamping(0)
	body:SetAirAngularDamping(0)
	body:SetLockRotation(true)
	body:SetGroundedSettling(false)
	body:SetFilterFunction(ignore_ragdoll_parts)
	body:SetBuoyancyDensity(self.BodyDensity)
	body:SetFriction(0)
	body:SetRollingFriction(0)
	body:SetRollingFrictionCombineMode(nil)
	body:SetCollisionMask(bit.bnot(usercmd.HELD_COLLISION_GROUP))
	self:ResetBodyRotation()
	self.Owner.transform.RenderOffset:Set(0, 0, 0)
	self.Owner.transform:SetPosition(position)
	body:SynchronizeFromTransform()
	body.PreviousPosition = body.Position:Copy()

	if mode == "walk" then
		body:SetCollisionEnabled(true)
		body:SetGravityScale(self.Gravity / body:GetPhysics().Gravity:GetLength())
		body:SetMinGroundNormalY(self.MinGroundNormalY)
		body:SetMaxLinearSpeed(self.WalkMaxLinearSpeed)
		self.was_grounded = false
	else
		body:SetCollisionEnabled(false)
		body:SetGravityScale(0)
		body:SetMaxLinearSpeed(
			self.FlySpeed * self.FlySpeedMaxMultiplier * math.max(1, self.SprintMultiplier, self.SuperMultiplier)
		)
		self.fly_speed_multiplier = 1
	end

	self.Owner:CallLocalEvent("OnCharacterModeChanged", mode)
end

do
	local function approach_vec(current, target, delta)
		local diff = target - current
		local length = diff:GetLength()

		if length == 0 or delta <= 0 then return current end

		if length <= delta then return target end

		return current + diff / length * delta
	end

	local function flatten_direction(dir, fallback)
		dir = Vec3(dir.x, 0, dir.z)

		if dir:GetLength() <= 0.0001 then return fallback:Copy() end

		return dir:GetNormalized()
	end

	local BUTTON = usercmd.BUTTON

	function META:OnUpdate(dt)
		local offset = self.Owner.transform.RenderOffset
		local smooth = offset.y

		if smooth ~= 0 then
			local decay = math.max(math.abs(smooth) * STEP_SMOOTH_SPEED, STEP_SMOOTH_MIN_SPEED) * dt
			offset.y = math.abs(smooth) <= decay and 0 or smooth - math.sign(smooth) * decay
		end
	end

	function META:OnPhysicsUpdate(dt)
		local body = self.Owner.rigid_body
		local cmd = self:GetController():NextCommand(dt)
		local health = self.Owner.health

		if self.was_grounded then
			local velocity = body:GetVelocity()
			local rotation = self.Owner.transform:GetRotation()
			local forward, right = rotation:GetForward(), rotation:GetRight()
			local along = velocity.x * forward.x + velocity.z * forward.z
			local across = velocity.x * right.x + velocity.z * right.z
			self.distance = self.distance + math.sqrt(velocity.x * velocity.x + velocity.z * velocity.z) * dt * pose_variation.GetStrideScale(along, across, self:IsCrouching())
		end

		if health and health:IsDead() then
			if not self.dead then self:Die() end

			if
				network.HasAuthority() and
				system.GetElapsedTime() - self.death_time >= self.RespawnDelay and
				usercmd.HasButton(cmd, BUTTON.ACTIVE) and
				usercmd.WasPressed(cmd, BUTTON.ATTACK1)
			then
				event.Call("PlayerRespawn", self.Owner)
			end

			return
		elseif self.dead then
			self:Reset(cmd.mode)
		end

		if self.Owner.ragdoll and self.Owner.ragdoll.Limp then return end

		if cmd.mode ~= self.mode then self:ApplyMode(cmd.mode) end

		if not self.frame_body_yaw then self:SetBodyYaw(cmd.view) end

		local view = cmd.view
		local active = usercmd.HasButton(cmd, BUTTON.ACTIVE)
		local crouching = usercmd.HasButton(cmd, BUTTON.CROUCH)

		if
			self.mode == "walk" and
			not self.Swimming and
			not crouching and
			self:IsCrouching() and
			not self:CanStand()
		then
			crouching = true
		end

		local sprinting = usercmd.HasButton(cmd, BUTTON.SPRINT)
		local walking = usercmd.HasButton(cmd, BUTTON.WALK)
		local speed_multiplier = 1

		if sprinting and crouching then
			speed_multiplier = self.SuperMultiplier
		elseif crouching then
			speed_multiplier = self.CrouchMultiplier
		elseif walking then
			speed_multiplier = self.WalkMultiplier
		elseif sprinting then
			speed_multiplier = self.SprintMultiplier
		end

		local jump_requested = active and usercmd.WasPressed(cmd, BUTTON.JUMP)
		local jump_down = usercmd.HasButton(cmd, BUTTON.JUMP)

		if self.mode == "walk" then
			local submerged = body.SubmergedFraction or 0

			if self.Swimming then
				if submerged < self.SwimExitFraction then self.Swimming = false end
			elseif submerged >= self.SwimEnterFraction then
				self.Swimming = true
				self.was_grounded = false
				self.ground_x = nil
				self.ground_z = nil
				self.ground_body = nil
			end

			if self.Swimming then
				self.previous_valid = false
				self:SetCrouch(false)
				self:UpdateCrouchTransition(dt)
				local wish = Vec3()

				if active then
					wish = view:GetForward() * cmd.forward + view:GetRight() * cmd.side

					if jump_down then
						wish.y = wish.y + 1
					elseif crouching then
						wish.y = wish.y - 1
					end
				end

				if wish:GetLength() > 0.0001 then
					local speed = self.SwimSpeed * (sprinting and self.SwimSprintMultiplier or 1)
					local target = wish:GetNormalized() * speed

					if target.y > 0 then
						target.y = target.y * math.clamp((submerged - self.SwimExitFraction) * 4, 0, 1)
					end

					body:SetVelocity(approach_vec(body:GetVelocity():Copy(), target, self.SwimAcceleration * dt))
				end

				return
			end

			self:SetCrouch(crouching)
			self:UpdateCrouchTransition(dt)
			local move = Vec3()

			if active then
				local forward = flatten_direction(view:GetForward(), Vec3(0, 0, -1))
				local right = flatten_direction(view:GetRight(), Vec3(1, 0, 0))
				move = forward * cmd.forward + right * cmd.side

				if move:GetLength() > 0.0001 then move = move:GetNormalized() end
			end

			local wish_speed = move:GetLength() > 0.0001 and self.GroundSpeed * speed_multiplier or 0
			local velocity = body:GetVelocity()
			local carrier = self.ground_body
			local base_x, base_y, base_z = 0, 0, 0

			if carrier and carrier:IsValid() then
				local carry = get_carry_velocity(carrier, body:GetOriginPosition(), dt)
				base_x, base_y, base_z = carry.x, carry.y, carry.z
			end

			local x, y, z = velocity.x - base_x, velocity.y - base_y, velocity.z - base_z
			local grounded = body:GetGrounded()
			local impact = 0

			if self.previous_valid and (body.SubmergedFraction or 0) <= 0 then
				local previous = self.previous_velocity
				local lost_x = math.max((previous.x - x) * math.sign(previous.x), 0)
				local lost_y = math.max((previous.y - y) * math.sign(previous.y), 0)
				local lost_z = math.max((previous.z - z) * math.sign(previous.z), 0)
				impact = math.sqrt(lost_x * lost_x + lost_y * lost_y + lost_z * lost_z)
			end

			self.previous_velocity:Set(x, y, z)
			self.previous_valid = true

			if y <= 0 then self.jumping = false end

			self.flat_ground_time = self.flat_ground_time - dt
			self.step_hold_time = self.step_hold_time - dt
			local rising = y > self.LeaveGroundSpeed
			local ground_normal
			local ground_body

			if rising or self.jumping then
				grounded = false
			elseif grounded or y <= 0 or self.was_grounded then
				local reach = self.was_grounded and
					(
						y > 0 or
						self:IsStickToGround() or
						self.flat_ground_time > 0
					)
					and
					self.StepHeight or
					self.GroundReach
				local found, gap, normal, found_body = self:FindGround(reach)
				grounded = found or grounded

				if found then
					ground_normal = normal
					ground_body = found_body

					if normal.y >= FLAT_GROUND_NORMAL_Y then
						self.flat_ground_time = FLAT_GROUND_MEMORY
					end

					if gap > 0 and reach > self.GroundReach and self.step_hold_time <= 0 then
						self:MoveBodyBy(body, Vec3(0, -gap, 0))
						self.Owner.transform.RenderOffset.y = self.Owner.transform.RenderOffset.y + gap
					end
				end
			end

			if grounded then
				if self.was_grounded and y > 0 and self.ground_x then
					if x * x + z * z < self.ground_x * self.ground_x + self.ground_z * self.ground_z then
						x = self.ground_x
						z = self.ground_z
					end
				end

				y = 0
			end

			local position = body:GetPosition()
			local roll = self.roll
			local crouch_down = usercmd.HasButton(cmd, BUTTON.CROUCH)

			if roll and not roll.leaving and not (crouch_down and grounded) then
				roll.leaving = 0
			end

			if roll then
				roll.time = roll.time + dt
				local fade = 1

				if roll.leaving then
					roll.leaving = roll.leaving + dt
					local out = math.clamp(roll.leaving / ROLL_EXIT, 0, 1)
					fade = 1 - out * out * (3 - 2 * out)
				end

				if roll.leaving and roll.leaving >= ROLL_EXIT then
					self.roll = nil
				else
					move = flatten_direction(view:GetForward(), Vec3(0, 0, -1)) * roll.forward + flatten_direction(view:GetRight(), Vec3(1, 0, 0)) * roll.side
					local decay = math.clamp((roll.time - ROLL_HOLD) / ROLL_DECAY, 0, 1)
					wish_speed = math.lerp(decay * decay * (3 - 2 * decay), roll.speed, self.RollSpeed) * math.lerp(fade, ROLL_FLOOR, 1)
					jump_requested = false
				end
			elseif
				active and
				grounded and
				usercmd.WasPressed(cmd, BUTTON.CROUCH) and
				wish_speed > 0 and
				event.Call("CanRoll", self.Owner) ~= false
			then
				local forward, side = cmd.forward, cmd.side
				local length = math.sqrt(forward * forward + side * side)
				forward, side = forward / length, side / length
				local direction = flatten_direction(view:GetForward(), Vec3(0, 0, -1)) * forward + flatten_direction(view:GetRight(), Vec3(1, 0, 0)) * side
				self.roll = {
					time = 0,
					speed = math.max(self.RollSpeed, math.sqrt(x * x + z * z) * ROLL_ENTRY),
					forward = forward,
					side = side,
					kind = classify_roll(direction, self.Owner.transform:GetRotation()),
				}
			end

			MOVE.velocity:Set(x, y, z)
			MOVE.position:Set(position.x, position.y, position.z)
			MOVE.grounded = grounded
			MOVE.jump_pressed = jump_requested
			MOVE.jump_down = jump_down
			MOVE.pitch = math.asin(math.clamp(view:GetForward().y, -1, 1))
			MOVE.dt = dt
			MOVE.move:Set(move.x, move.y, move.z)
			MOVE.wish_speed = wish_speed
			event.Call("PlayerMove", self.Owner, MOVE)
			x, y, z = MOVE.velocity.x, MOVE.velocity.y, MOVE.velocity.z
			move = MOVE.move:Copy()
			wish_speed = MOVE.wish_speed
			jump_requested = MOVE.jump_pressed
			local lunge = self.lunge

			if lunge then
				if lunge.delay > 0 then
					lunge.delay = lunge.delay - dt
				else
					local from = lunge.elapsed / lunge.time
					lunge.elapsed = lunge.elapsed + dt
					local to = math.min(lunge.elapsed / lunge.time, 1)

					if not self:IsRolling() then
						move = lunge.direction:Copy()
						wish_speed = lunge.distance * (math.cos(math.pi * from) - math.cos(math.pi * to)) / 2 / dt
					end

					if to >= 1 - 1e-6 then self.lunge = nil end
				end
			end

			if grounded and not MOVE.grounded then body:SetGrounded(false) end

			grounded = MOVE.grounded

			if grounded and not self.was_grounded then
				impact = math.max(impact, -velocity.y)
			end

			if impact > 0 then self:Impact(impact) end

			if grounded and jump_requested then
				y = self.JumpSpeed
				self.jumping = true
				grounded = false
				body:SetGrounded(false)
			end

			if grounded then
				local speed = math.sqrt(x * x + z * z)

				if speed >= 0.0001 then
					local control = math.max(speed, self.StopSpeed)
					local scale = math.max(speed - control * self.Friction * dt, 0) / speed
					x = x * scale
					z = z * scale
				end
			end

			if wish_speed > 0 then
				local limit = grounded and wish_speed or math.min(wish_speed, self.AirSpeed)
				local acceleration = grounded and self.Acceleration or self.AirAcceleration
				local add_speed = limit - (x * move.x + z * move.z)

				if add_speed > 0 then
					local gain = math.min(acceleration * dt * wish_speed, add_speed)
					x = x + move.x * gain
					z = z + move.z * gain
				end
			end

			if grounded and y == 0 and ground_normal then
				y = -(x * ground_normal.x + z * ground_normal.z) / ground_normal.y
			end

			if grounded and wish_speed > 0 then
				local speed = math.sqrt(x * x + z * z)

				if speed > 0.0001 then
					self:TryStepUp(Vec3(x / speed, 0, z / speed), speed * dt)
				end
			end

			if ground_body then
				local carry = get_carry_velocity(ground_body, body:GetOriginPosition(), dt)
				base_x, base_y, base_z = carry.x, carry.y, carry.z
			end

			body:ApplyImpulse(
				Vec3(x + base_x - velocity.x, y + base_y - velocity.y, z + base_z - velocity.z) / body.InverseMass
			)

			if grounded and ground_normal then
				local ny = ground_normal.y
				local weight = self.Gravity / body.InverseMass
				body:ApplyForce(Vec3(ground_normal.x * ny, -(1 - ny * ny), ground_normal.z * ny) * -weight)
			end

			self.was_grounded = grounded
			self.ground_body = grounded and ground_body or nil
			self.ground_x = grounded and x or nil
			self.ground_z = grounded and z or nil
			return
		end

		if not active then
			self.fly_speed_multiplier = 1
			body:SetVelocity(Vec3())
			body:SetAngularVelocity(Vec3())
			return
		end

		local forward = view:GetForward() * cmd.forward
		local right = view:GetRight() * cmd.side
		local up = view:GetUp() * cmd.up
		local fov = cmd.fov

		if right:GetLength() > 0 then
			if fov > math.rad(90) then
				right = right / ((fov / math.rad(90)) ^ 4)
			else
				right = right / ((fov / math.rad(90)) ^ 0.25)
			end
		end

		local move = forward + right + up
		local moving = move:GetLength() > 0.0001

		if moving then
			move = move:GetNormalized()

			if speed_multiplier > 1 then
				self.fly_speed_multiplier = math.min(
					self.fly_speed_multiplier * (1 + dt * self.FlySpeedRamp),
					self.FlySpeedMaxMultiplier
				)
			else
				self.fly_speed_multiplier = 1
			end
		else
			self.fly_speed_multiplier = 1
		end

		local velocity = body:GetVelocity():Copy()
		local target = move * (
				moving and
				speed_multiplier * self.FlySpeed * self.fly_speed_multiplier or
				0
			)
		local rate = target:GetLength() < velocity:GetLength() and
			self.FlyBrake or
			self.FlyAccelerate
		body:SetVelocity(velocity + (target - velocity) * (1 - math.exp(-rate * dt)))
		body:SetAngularVelocity(Vec3())
	end
end

return META:Register()
