local objects = import("goluwa/objects/objects.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local META = objects.CreateTemplate("player_movement")
META:IsSet("Crouching", false)
META:GetSet("GroundSpeed", 10)
META:GetSet("AirSpeed", 3.8)
META:GetSet("Acceleration", 45)
META:GetSet("AirAcceleration", 18)
META:GetSet("JumpSpeed", 8)
META:GetSet("GroundSnapDistance", 0.08)
META:GetSet("StepHeight", 0.35)
META:GetSet("EyeHeight", 1.75)
META:GetSet("Radius", 0.35)
META:GetSet("Height", 2)
META:GetSet("CrouchScale", 0.5)
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
	self:OnCameraModeChanged(self.Owner.player_input)
end

function META:GetDimensions(alpha)
	alpha = alpha == nil and (self.crouch_alpha or (self:IsCrouching() and 1 or 0)) or alpha
	return math.lerp(alpha, self.Radius, self.Radius * self.CrouchScale),
	math.lerp(alpha, self.Height, self.Height * self.CrouchScale),
	math.lerp(alpha, self.EyeHeight, self.EyeHeight * self.CrouchScale)
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
	body:SetLinearDamping(10)
	body:SetAirLinearDamping(0)
	body:SetAngularDamping(40)
	body:SetAirAngularDamping(40)
	body:SetFriction(0)

	if mode == "walk" then
		body:SetCollisionEnabled(true)
		body:SetGravityScale(1)
		body:SetMaxLinearSpeed(self.WalkMaxLinearSpeed)
		self.Owner.transform:SetPosition(render3d.GetCamera():GetPosition():Copy() - self:GetEyeOffset())
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
		self.Owner.transform:SetPosition(render3d.GetCamera():GetPosition():Copy())
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

	function META:OnCameraInputUpdate(dt, state)
		local transform = self.Owner.transform
		local look = self.Owner.player_input
		local camera = self.Owner.camera
		local body = self.Owner.rigid_body

		if not (transform and look) then return end

		if look.Mode == "walk" then
			self:SetCrouch(state.crouching)
			self:UpdateCrouchTransition(dt)
			self:ResetBodyRotation()
			camera:SetViewOffset(self:GetEyeOffset())

			if not state.mouse_trapped then
				local velocity = body:GetVelocity():Copy()
				velocity.x = 0
				velocity.z = 0
				body:SetVelocity(velocity)
				body:SetAngularVelocity(Vec3())
				return
			end

			local forward = flatten_direction(look:GetForward(), Vec3(0, 0, -1))
			local right = flatten_direction(look:GetRight(), Vec3(1, 0, 0))
			local move = forward * state.move_local.z + right * state.move_local.x

			if move:GetLength() > 0.0001 then move = move:GetNormalized() end

			local grounded = body:GetGrounded()

			if grounded then
				local move_speed = (grounded and self.GroundSpeed or self.AirSpeed) * state.speed_multiplier
				local acceleration = grounded and self.Acceleration or self.AirAcceleration
				local velocity = body:GetVelocity():Copy()
				local horizontal_velocity = approach_vec(
					Vec3(velocity.x, 0, velocity.z),
					move * move_speed,
					acceleration * dt * 10
				)
				velocity.x = horizontal_velocity.x
				velocity.z = horizontal_velocity.z

				if state.jump_pressed and grounded then
					velocity.y = self.JumpSpeed
					body:SetGrounded(false)
				end

				body:SetVelocity(velocity)
			end

			return
		end

		camera:SetViewOffset(Vec3())
		self:ResetBodyRotation()

		if not state.mouse_trapped then
			self.fly_speed_multiplier = 1
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
