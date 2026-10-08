local objects = import("goluwa/objects/objects.lua")
local system = import("goluwa/system.lua")
local steam = import("goluwa/steam/steam.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local event = import("goluwa/event.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local META = objects.CreateTemplate("player_movement")
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
META:GetSet("FlySpeedRamp", 0.75)
META:GetSet("FlySpeedMaxMultiplier", 500)
META:GetSet("WalkMaxLinearSpeed", 240)
META:GetSet("SprintMultiplier", 2)
META:GetSet("CrouchMultiplier", 1 / 3)
META:GetSet("SuperMultiplier", 3)
META:GetSet("Mode", "fly")
META:GetSet("SwimSpeed", 3)
META:GetSet("SwimSprintMultiplier", 1.6)
META:GetSet("SwimAcceleration", 30)
META:GetSet("SwimEnterFraction", 0.75)
META:GetSet("SwimExitFraction", 0.5)
META:IsSet("Swimming", false)
-- a lean adult with the lungs mostly emptied, a little denser than water so they sink slowly
META:GetSet("BodyDensity", 1060)

function META:Initialize()
	self.Owner:EnsureComponent("transform")
	self.Owner:EnsureComponent("rigid_body")
	assert(self.Owner.rigid_body)
	self.crouch_alpha = self:IsCrouching() and 1 or 0
	self.fly_speed_multiplier = 1
	self.step_smooth = 0
	self:AddGlobalEvent("PhysicsUpdate")
	self.mode = nil
	self:ApplyMode(self.Mode)
end

function META:Reset(mode)
	self.mode = nil
	self.Crouching = false
	self.crouch_alpha = 0
	self.CrouchTransition = false
	self.CrouchAnchorMode = nil
	self.CrouchAnchorPosition = nil
	self.was_grounded = false
	self.Swimming = false
	self.ground_x = nil
	self.ground_z = nil
	self.jump_requested = nil
	self.fly_speed_multiplier = 1
	self.step_smooth = 0
	self:InvalidateBodyGeometry()
	self:ApplyMode(mode)
end

function META:GetViewOffset()
	if self.mode == "walk" then return self:GetEyeOffset() end

	return Vec3()
end

function META:GetDimensions(alpha)
	alpha = alpha == nil and (self.crouch_alpha or (self:IsCrouching() and 1 or 0)) or alpha
	return self.Radius,
	math.lerp(alpha, self.Height, self.CrouchHeight),
	math.lerp(alpha, self.EyeHeight, self.CrouchEyeHeight)
end

function META:GetEyeOffset(alpha)
	local _, height, eye_height = self:GetDimensions(alpha)
	return Vec3(0, eye_height - height * 0.5 + self.step_smooth, 0)
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
local STEP_REACH_MARGIN = 0.03
local STEP_PROBE_BACKOFF = 0.05
local STEP_MIN_GAIN = 0.005
local GROUND_RAY_LIFT = 0.02
local STEP_SMOOTH_SPEED = 8
local STEP_SMOOTH_MIN_SPEED = 1
local STEP_OPTIONS = {Rotation = nil}

function META:MoveBodyBy(body, offset)
	local velocity = body:GetVelocity():Copy()
	self.Owner.transform:SetPosition(body:GetPosition() + offset)
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
	self.step_smooth = self.step_smooth - lift
	return true
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
	local ground_distance

	if hit and hit.normal.y >= self.MinGroundNormalY then
		ground_distance = sweep_length * hit.fraction
	else
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
		return true, math.max(ground_distance - resting_gap, 0), ray.normal
	end

	return true, math.max(ground_distance - resting_gap, 0), hit.normal
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

function META:ApplyMode(mode)
	local body = self.Owner.rigid_body
	local previous = self.mode
	self.mode = mode
	self.Swimming = false
	self.Mode = mode

	if not body then return end

	local radius, height = self:GetDimensions()
	local position = self.Owner.transform:GetPosition():Copy()

	if previous == "walk" and mode == "fly" then
		position = position + self:GetEyeOffset()
	elseif previous == "fly" and mode == "walk" then
		position = position - self:GetEyeOffset()
	end

	body:SetMotionType("dynamic")
	body:SetShape(CapsuleShape.New(radius, height))
	body:SetCCD(true)
	body:SetCanSleep(false)
	body:SetLinearDamping(0)
	body:SetAirLinearDamping(0)
	body:SetAngularDamping(0)
	body:SetAirAngularDamping(0)
	body:SetLockRotation(true)
	body:SetBuoyancyDensity(self.BodyDensity)
	body:SetFriction(0)
	body:SetCollisionMask(bit.bnot(usercmd.HELD_COLLISION_GROUP))
	self:ResetBodyRotation()
	self.step_smooth = 0
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

	self.Owner:CallLocalEvent("OnPlayerModeChanged", mode)
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

	function META:OnPhysicsUpdate(dt)
		local body = self.Owner.rigid_body
		local cmd = self.Owner.player_controller:NextCommand(dt)

		if cmd.mode ~= self.mode then self:ApplyMode(cmd.mode) end

		local view = cmd.view
		local active = usercmd.HasButton(cmd, BUTTON.ACTIVE)
		local crouching = usercmd.HasButton(cmd, BUTTON.CROUCH)
		local sprinting = usercmd.HasButton(cmd, BUTTON.SPRINT)
		local speed_multiplier = 1

		if sprinting and crouching then
			speed_multiplier = self.SuperMultiplier
		elseif sprinting then
			speed_multiplier = self.SprintMultiplier
		elseif crouching then
			speed_multiplier = self.CrouchMultiplier
		end

		local jump_requested = active and usercmd.WasPressed(cmd, BUTTON.JUMP)
		local jump_down = usercmd.HasButton(cmd, BUTTON.JUMP)

		if self.mode == "walk" then
			local smooth = self.step_smooth

			if smooth ~= 0 then
				local decay = math.max(math.abs(smooth) * STEP_SMOOTH_SPEED, STEP_SMOOTH_MIN_SPEED) * dt
				self.step_smooth = math.abs(smooth) <= decay and 0 or smooth - math.sign(smooth) * decay
			end

			local submerged = body.SubmergedFraction or 0

			if self.Swimming then
				if submerged < self.SwimExitFraction then self.Swimming = false end
			elseif submerged >= self.SwimEnterFraction then
				self.Swimming = true
				self.was_grounded = false
				self.ground_x = nil
				self.ground_z = nil
			end

			if self.Swimming then
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
			local x, y, z = velocity.x, velocity.y, velocity.z
			local grounded = body:GetGrounded()
			local rising = y > self.LeaveGroundSpeed
			local ground_normal

			if rising then
				grounded = false
			elseif grounded or y <= 0 or self.was_grounded then
				local reach = self.was_grounded and
					(
						y > 0 or
						self:IsStickToGround()
					)
					and
					self.StepHeight or
					self.GroundReach
				local found, gap, normal = self:FindGround(reach)
				grounded = found or grounded

				if found then
					ground_normal = normal

					if gap > 0 and reach > self.GroundReach then
						self:MoveBodyBy(body, Vec3(0, -gap, 0))
						self.step_smooth = self.step_smooth + gap
					end
				end
			end

			local along = x * move.x + z * move.z

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
			MOVE.velocity:Set(x, y, z)
			MOVE.position:Set(position.x, position.y, position.z)
			MOVE.grounded = grounded
			MOVE.jump_pressed = jump_requested
			MOVE.jump_down = jump_down
			MOVE.pitch = math.asin(math.clamp(view:GetForward().y, -1, 1))
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

			body:ApplyImpulse(Vec3(x - velocity.x, y - velocity.y, z - velocity.z) / body.InverseMass)
			self.was_grounded = grounded
			self.ground_x = grounded and x or nil
			self.ground_z = grounded and z or nil

			if grounded and wish_speed > 0 then
				if along < wish_speed * 0.5 then
					self:TryStepUp(move, math.sqrt(x * x + z * z) * dt)
				end
			end

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

		body:SetVelocity(
			approach_vec(
				body:GetVelocity():Copy(),
				move * speed_multiplier * self.FlySpeed * self.fly_speed_multiplier,
				self.Acceleration * dt * 10
			)
		)
		body:SetAngularVelocity(Vec3())
	end
end

return META:Register()
