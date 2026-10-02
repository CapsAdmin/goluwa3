local objects = import("goluwa/objects/objects.lua")
local system = import("goluwa/system.lua")
local steam = import("goluwa/steam/steam.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local event = import("goluwa/event.lua")
local META = objects.CreateTemplate("player_movement")
-- Source's player (GMod defaults) in Source units, converted to meters. Source
-- uses a 32 x 72 box hull that moves by itself; this is a capsule on a rigid
-- body, so the width becomes its diameter and the height its total height.
-- The velocity follows Source's friction and acceleration (sv_friction,
-- sv_stopspeed, sv_accelerate, sv_airaccelerate), applied to the body as
-- impulses. The body's own friction and damping are off, the solver only
-- provides the collision response.
local UNIT = steam.source2meters
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
-- Source's sv_sticktoground: keep the body on the ground over crests and down
-- slopes instead of letting it leave the surface
META:IsSet("StickToGround", true)
-- Source leaves the ground at 140 u/s, which running up a 30 degree ramp
-- already reaches; here only a jump or a real launch does
META:GetSet("LeaveGroundSpeed", 250 * UNIT)
META:GetSet("MinGroundNormalY", 0.7)
META:GetSet("Radius", 16 * UNIT)
META:GetSet("Height", 72 * UNIT)
META:GetSet("EyeHeight", 64 * UNIT)
META:GetSet("CrouchHeight", 36 * UNIT)
META:GetSet("CrouchEyeHeight", 28 * UNIT)
META:GetSet("CrouchTransitionTime", 0.05)
META:GetSet("FlySpeed", 30)
META:GetSet("FlySpeedRamp", 0.75)
META:GetSet("FlySpeedMaxMultiplier", 500)
META:GetSet("WalkMaxLinearSpeed", 240)

function META:Initialize()
	self.Owner:EnsureComponent("transform")
	self.Owner:EnsureComponent("rigid_body")
	assert(self.Owner.rigid_body)
	self.crouch_alpha = self:IsCrouching() and 1 or 0
	self.fly_speed_multiplier = 1
	self:AddGlobalEvent("PhysicsUpdate")
	self:OnCameraModeChanged(self.Owner.player_input)
end

function META:GetDimensions(alpha)
	alpha = alpha == nil and (self.crouch_alpha or (self:IsCrouching() and 1 or 0)) or alpha
	return self.Radius,
	math.lerp(alpha, self.Height, self.CrouchHeight),
	math.lerp(alpha, self.EyeHeight, self.CrouchEyeHeight)
end

function META:GetEyeOffset(alpha)
	local _, height, eye_height = self:GetDimensions(alpha)
	return Vec3(0, eye_height - height * 0.5, 0)
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
	body:RefreshMassProperties()

	if body.SetAwake then body:SetAwake(true) end
end

function META:ApplyCrouchAlpha(alpha)
	local body = self.Owner.rigid_body
	local camera = self.Owner.camera

	if not body then return end

	self.crouch_alpha = alpha
	local radius, height = self:GetDimensions(alpha)
	local shape = body:GetPhysicsShape()

	if shape and shape.GetTypeName and shape:GetTypeName() == "capsule" then
		shape:SetRadius(radius)
		shape:SetHeight(height)
		self:InvalidateBodyGeometry()
	end

	if self.CrouchAnchorMode and self.CrouchAnchorPosition then
		local new_position

		if self.CrouchAnchorMode == "feet" then
			new_position = self.CrouchAnchorPosition + Vec3(0, height * 0.5, 0)
		else
			new_position = self.CrouchAnchorPosition - Vec3(0, height * 0.5, 0)
		end

		local velocity = body:GetVelocity():Copy()
		local angular_velocity = body:GetAngularVelocity():Copy()
		self.Owner.transform:SetPosition(new_position)
		body:SynchronizeFromTransform()
		body.PreviousPosition = body.Position:Copy()
		body:SetVelocity(velocity)
		body:SetAngularVelocity(angular_velocity)
	end

	if camera then camera:SetViewOffset(self:GetEyeOffset(alpha)) end
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

-- the probes start a little above the ground, a capsule resting on it already
-- touches it and would report the ground instead of what is in front of it
-- handed to the PlayerMove event every fixed step, like Source's CMoveData:
-- hooks read and change velocity and grounded before the controller applies
-- friction, acceleration and its own jump
local MOVE = {
	velocity = Vec3(),
	position = Vec3(),
	grounded = false,
	jump_pressed = false,
	jump_down = false,
	pitch = 0,
	dt = 0,
}
local STEP_PROBE_LIFT = 0.04
-- the body rests a margin away from what it touches
local STEP_REACH_MARGIN = 0.03
local STEP_PROBE_BACKOFF = 0.05
local STEP_MIN_GAIN = 0.005
local SNAP_MIN_EXCESS = 0.02
local GROUND_RAY_LIFT = 0.02
local STEP_SNAP_HOLD_TICKS = 12
local STEP_OPTIONS = {Rotation = nil}

function META:MoveBodyBy(body, offset)
	local velocity = body:GetVelocity():Copy()
	self.Owner.transform:SetPosition(body:GetPosition() + offset)
	body:SynchronizeFromTransform()
	body.PreviousPosition = body.Position:Copy()
	body:SetVelocity(velocity)
end

-- Source's StepMove: if the flat move is blocked, try the same move from a
-- step height up, come back down, and keep it when it goes further and lands on
-- walkable ground. direction is the horizontal unit direction of the move and
-- distance how far this tick moves the body.
-- A box hull is flat on a ledge as soon as its edge is over it, a capsule is
-- round: its centre has to get close to the ledge's edge before it lands on
-- the top, so the probe moves at least half a radius.
function META:TryStepUp(direction, distance)
	local body = self.Owner.rigid_body
	local physics = body:GetPhysics()
	local collider = body:GetColliders()[1]
	local owner = self.Owner
	local filter = body:GetFilterFunction()
	local position = body:GetPosition()
	STEP_OPTIONS.Rotation = body:GetRotation()
	-- the contact solver lets the body sink a little into what it pushes
	-- against, and a sweep that starts overlapping hits at once whatever way it
	-- goes, so the probes start behind the body
	local start = position + Vec3(0, STEP_PROBE_LIFT, 0) - direction * STEP_PROBE_BACKOFF
	local reach_length = STEP_PROBE_BACKOFF + math.max(distance + STEP_REACH_MARGIN, self.Radius * 0.5)
	local reach = direction * reach_length
	local flat = physics.SweepCollider(collider, start, reach, owner, filter, STEP_OPTIONS)

	if not flat or flat.normal.y >= self.MinGroundNormalY then return false end

	local flat_distance = reach_length * flat.fraction
	local up = Vec3(0, self.StepHeight - STEP_PROBE_LIFT, 0)
	local up_hit = physics.SweepCollider(collider, start, up, owner, filter, STEP_OPTIONS)
	local raised = start + up * (up_hit and up_hit.fraction or 1)
	local across = physics.SweepCollider(collider, raised, reach, owner, filter, STEP_OPTIONS)
	local across_distance = reach_length * (across and across.fraction or 1)

	if across_distance <= flat_distance + STEP_MIN_GAIN then return false end

	local landing = raised + reach * (across and across.fraction or 1)
	local drop = Vec3(0, -(self.StepHeight + STEP_PROBE_LIFT), 0)
	local down = physics.SweepCollider(collider, landing, drop, owner, filter, STEP_OPTIONS)

	if not down or down.normal.y < self.MinGroundNormalY then return false end

	local lift = landing.y + drop.y * down.fraction - position.y

	if lift <= STEP_MIN_GAIN or lift > self.StepHeight + STEP_MIN_GAIN then
		return false
	end

	self:MoveBodyBy(body, Vec3(0, lift, 0))
	-- the body is above the step and still has to move onto it, putting it
	-- back on the ground now would undo the step
	self.snap_hold = STEP_SNAP_HOLD_TICKS
	return true
end

-- sweeps the player's own capsule from where it is, for movement hooks
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

-- Source's ground check: the body is on the ground when walkable ground is
-- within reach below it. Right after standing it reaches a whole step, so
-- walking down a ramp or stairs, where the body would fall off every edge and
-- lose its ground friction for a tick, puts it back on the ground (Source's
-- StayOnGround). Otherwise it reaches 2 units, which is how close a landing
-- body has to be to count as standing. The second result is how far the body
-- is above the ground when it should be put back on it; the caller does that
-- with a velocity, so the physics moves the body and it stays interpolated.
function META:FindGround(reach)
	local body = self.Owner.rigid_body
	local physics = body:GetPhysics()
	STEP_OPTIONS.Rotation = body:GetRotation()
	-- a body rests a margin away from the ground and the ground a margin away
	-- from it, the reach is measured from there
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
	local ground_distance

	if hit and hit.normal.y >= self.MinGroundNormalY then
		ground_distance = sweep_length * hit.fraction
	else
		-- a round bottom touching a stair's edge reports a sloped contact
		-- where a box hull would stand flat on the step: the surface right
		-- under the body decides
		local _, height = self:GetDimensions()
		local origin = body:GetPosition() - Vec3(0, height * 0.5 - GROUND_RAY_LIFT, 0)
		local ray = physics.RayCast(
			origin,
			Vec3(0, -1, 0),
			sweep_length + GROUND_RAY_LIFT,
			self.Owner,
			body:GetFilterFunction()
		)

		if not ray or ray.normal.y < self.MinGroundNormalY then return false end

		ground_distance = ray.distance - GROUND_RAY_LIFT
	end

	local excess = ground_distance - resting_gap

	if reach > self.GroundReach and excess > SNAP_MIN_EXCESS and not self.snap_hold then
		return true, excess
	end

	return true, 0
end

function META:SetCrouch(b)
	local body = self.Owner.rigid_body

	if not body then return end

	if self:IsCrouching() == b then return end

	local _, current_height = self:GetDimensions()
	local position = body:GetPosition():Copy()
	self.CrouchTransition = true
	self.CrouchTransitionElapsed = 0
	self.CrouchTransitionStartAlpha = self.crouch_alpha or (self:IsCrouching() and 1 or 0)
	self.CrouchTransitionTargetAlpha = b and 1 or 0

	if body:GetGrounded() then
		self.CrouchAnchorMode = "feet"
		self.CrouchAnchorPosition = position - Vec3(0, current_height * 0.5, 0)
	else
		self.CrouchAnchorMode = "head"
		self.CrouchAnchorPosition = position + Vec3(0, current_height * 0.5, 0)
	end

	self.Crouching = b
end

function META:OnCameraModeChanged(mode)
	local body = self.Owner.rigid_body
	local camera = self.Owner.camera
	local input = self.Owner.player_input

	if not body then return end -- too early
	local radius, height = self:GetDimensions()
	body:SetMotionType("dynamic")
	body:SetShape(CapsuleShape.New(radius, height))
	body:SetCCD(true)
	body:SetCanSleep(false)
	body:SetLinearDamping(0)
	body:SetAirLinearDamping(0)
	body:SetAngularDamping(0)
	body:SetAirAngularDamping(0)
	body:SetLockRotation(true)
	body:SetFriction(0)
	self:ResetBodyRotation()

	if mode == "walk" then
		body:SetCollisionEnabled(true)
		-- the world's gravity is tuned for other things, the player falls like
		-- a Source player
		body:SetGravityScale(self.Gravity / body:GetPhysics().Gravity:GetLength())
		body:SetMinGroundNormalY(self.MinGroundNormalY)
		body:SetMaxLinearSpeed(self.WalkMaxLinearSpeed)
		self.was_grounded = false
		self.Owner.transform:SetPosition(camera:GetView():GetPosition():Copy() - self:GetEyeOffset())
		body:SynchronizeFromTransform()
		body.PreviousPosition = body.Position:Copy()
		camera:SetViewOffset(self:GetEyeOffset())
	else
		local max_input_multiplier = 1

		if input then
			max_input_multiplier = math.max(
				max_input_multiplier,
				input.SprintMultiplier or 1,
				input.SuperMultiplier or 1
			)
		end

		body:SetCollisionEnabled(false)
		body:SetGravityScale(0)
		body:SetMaxLinearSpeed(self.FlySpeed * self.FlySpeedMaxMultiplier * max_input_multiplier)
		self.Owner.transform:SetPosition(camera:GetView():GetPosition():Copy())
		body:SynchronizeFromTransform()
		body.PreviousPosition = body.Position:Copy()
		camera:SetViewOffset(Vec3())
		self.fly_speed_multiplier = 1
	end
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

	-- once per rendered frame: everything that follows the camera and the
	-- player's input state; the body itself is driven from OnPhysicsUpdate
	function META:OnCameraInputUpdate(dt, state)
		local transform = self.Owner.transform
		local look = self.Owner.player_input
		local camera = self.Owner.camera

		if not (transform and look) then return end

		self.input_frame = system.GetFrameNumber()

		-- the input clears jump_pressed after every frame, and a frame may run
		-- no physics step at all
		if state.jump_pressed then self.jump_requested = true end

		if look.Mode == "walk" then
			self:SetCrouch(state.crouching)
			self:UpdateCrouchTransition(dt)
			camera:SetViewOffset(self:GetEyeOffset())
			return
		end

		camera:SetViewOffset(Vec3())

		if not state.mouse_trapped then self.fly_speed_multiplier = 1 end
	end

	-- once per fixed physics step, with the fixed step as dt, so the movement
	-- does not depend on the frame rate
	function META:OnPhysicsUpdate(dt)
		local look = self.Owner.player_input
		local body = self.Owner.rigid_body

		if not (look and body) then return end

		-- no camera input update ran recently (the camera is not rendered): the
		-- body keeps its velocity
		if not self.input_frame or system.GetFrameNumber() - self.input_frame > 1 then
			return
		end

		local state = look
		local jump_requested = self.jump_requested
		self.jump_requested = false

		if look.Mode == "walk" then
			local move = Vec3()

			if state.mouse_trapped then
				local forward = flatten_direction(look:GetForward(), Vec3(0, 0, -1))
				local right = flatten_direction(look:GetRight(), Vec3(1, 0, 0))
				move = forward * state.move_local.z + right * state.move_local.x

				if move:GetLength() > 0.0001 then move = move:GetNormalized() end
			else
				jump_requested = false
			end

			local wish_speed = move:GetLength() > 0.0001 and
				self.GroundSpeed * state.speed_multiplier or
				0
			local velocity = body:GetVelocity()
			local x, y, z = velocity.x, velocity.y, velocity.z
			local grounded = body:GetGrounded()

			if self.snap_hold then
				self.snap_hold = self.snap_hold > 1 and self.snap_hold - 1 or nil
			end

			-- like Source, rising faster than a slope can lift a walker means
			-- the body left the ground; below that, going over a crest keeps it
			-- on the ground and whatever vertical speed the slope gave it is dropped
			local rising = y > self.LeaveGroundSpeed
			local snap_down = 0

			if rising then
				grounded = false
			elseif not grounded and (y <= 0 or self.was_grounded) then
				grounded, snap_down = self:FindGround(
					self.was_grounded and
						self:IsStickToGround() and
						self.StepHeight or
						self.GroundReach
				)
			end

			if grounded then y = -snap_down / dt end

			local position = body:GetPosition()
			MOVE.velocity:Set(x, y, z)
			MOVE.position:Set(position.x, position.y, position.z)
			MOVE.grounded = grounded
			MOVE.jump_pressed = jump_requested
			MOVE.jump_down = state.jump_down
			MOVE.pitch = math.asin(math.clamp(look:GetForward().y, -1, 1))
			MOVE.dt = dt
			event.Call("PlayerMove", self.Owner, MOVE)
			x, y, z = MOVE.velocity.x, MOVE.velocity.y, MOVE.velocity.z

			if grounded and not MOVE.grounded then body:SetGrounded(false) end

			grounded = MOVE.grounded

			if grounded and jump_requested then
				y = self.JumpSpeed
				grounded = false
				body:SetGrounded(false)
			end

			if grounded then
				-- Source's Friction: the drop is a fraction of the speed, but
				-- never of less than the stop speed, so a slow body stops
				local speed = math.sqrt(x * x + z * z)

				if speed >= 0.0001 then
					local control = math.max(speed, self.StopSpeed)
					local scale = math.max(speed - control * self.Friction * dt, 0) / speed
					x = x * scale
					z = z * scale
				end
			end

			if wish_speed > 0 then
				-- Source's Accelerate and AirAccelerate: accelerate along the wish
				-- direction up to the wish speed, in the air up to a small cap
				local limit = grounded and wish_speed or math.min(wish_speed, self.AirSpeed)
				local acceleration = grounded and self.Acceleration or self.AirAcceleration
				local add_speed = limit - (x * move.x + z * move.z)

				if add_speed > 0 then
					local gain = math.min(acceleration * dt * wish_speed, add_speed)
					x = x + move.x * gain
					z = z + move.z * gain
				end
			end

			body:ApplyImpulse(Vec3(x - velocity.x, y - velocity.y, z - velocity.z) / body.InverseMass)
			self.was_grounded = grounded

			if grounded and wish_speed > 0 then
				local along = x * move.x + z * move.z

				if along < wish_speed * 0.5 then
					self:TryStepUp(move, math.sqrt(x * x + z * z) * dt)
				end
			end

			return
		end

		if not state.mouse_trapped then
			body:SetVelocity(Vec3())
			body:SetAngularVelocity(Vec3())
			return
		end

		local rotation = look:GetRotation()
		local forward = rotation:GetForward() * state.move_local.z
		local right = rotation:GetRight() * state.move_local.x
		local up = rotation:GetUp() * state.move_local.y
		local fov = look:GetFOV()

		if right:GetLength() > 0 then
			if fov > math.rad(90) then
				right = right / ((fov / math.rad(90)) ^ 4)
			else
				right = right / ((fov / math.rad(90)) ^ 0.25)
			end
		end

		local move = forward + right + up
		local moving = move:GetLength() > 0.0001
		local sprinting = state.speed_multiplier > 1

		if moving then
			move = move:GetNormalized()

			if sprinting then
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

		body:SetVelocity(
			approach_vec(
				body:GetVelocity():Copy(),
				move * state.speed_multiplier * self.FlySpeed * self.fly_speed_multiplier,
				self.Acceleration * dt * 10
			)
		)
		body:SetAngularVelocity(Vec3())
	end
end

return META:Register()
