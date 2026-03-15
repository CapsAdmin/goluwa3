local prototype = import("goluwa/prototype.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local META = prototype.CreateTemplate("player_movement")
META:GetSet("Initialized", false)
META:GetSet("Crouched", false)
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
META:GetSet("FlySpeed", 30)

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

function META:Initialize()
	self.Owner:EnsureComponent("transform")
	self.Owner:EnsureComponent("rigid_body")
	self:ConfigureBody(false)
	local input = self.Owner.player_input

	if input and input.Mode == "walk" then
		self:EnterWalkMode(true)
	else
		self:LeaveWalkMode()
	end
end

function META:GetRigidBody()
	return self.Owner and self.Owner.rigid_body or nil
end

function META:GetDimensions(crouched)
	if crouched then
		return self.Radius * self.CrouchScale, self.Height * self.CrouchScale, self.EyeHeight * self.CrouchScale
	end

	return self.Radius, self.Height, self.EyeHeight
end

function META:GetEyeOffset(crouched)
	local _, height, eye_height = self:GetDimensions(crouched)
	return Vec3(0, eye_height - height * 0.5, 0)
end

function META:ConfigureBody(crouched)
	local body = self:GetRigidBody()

	if not body then return end

	local radius, height = self:GetDimensions(crouched)
	body:SetMotionType("dynamic")
	body:SetShape(CapsuleShape.New(radius, height))
	body:SetLinearDamping(10)
	body:SetAirLinearDamping(0)
	body:SetAngularDamping(40)
	body:SetAirAngularDamping(40)
	body:SetFriction(0)
end

function META:ResetBodyRotation()
	local body = self:GetRigidBody()

	if not body then return end

	local rotation = Quat():Identity()
	self.Owner.transform:SetRotation(rotation)
	body:SetRotation(rotation)
	body.PreviousRotation = rotation:Copy()
	body:SetAngularVelocity(Vec3())
end

function META:InitializeFromCamera(reset_velocity)
	local body = self:GetRigidBody()
	local camera = self.Owner.camera
	local cam = render3d.GetCamera()

	if not (body and cam) then return end

	self.Owner.transform:SetPosition(cam:GetPosition():Copy() - self:GetEyeOffset(self.Crouched))
	self:ResetBodyRotation()
	body:SynchronizeFromTransform()
	body.PreviousPosition = body.Position:Copy()
	body:SetGrounded(false)
	body:SetEnabled(true)
	body:SetMotionType("dynamic")

	if reset_velocity or not self.Initialized then
		local zero = Vec3()
		body:SetVelocity(zero)
		body:SetAngularVelocity(zero)
	end

	if body.Wake then body:Wake() else body.Awake = true end
	body.SleepTimer = 0

	self.Initialized = true

	if camera then camera:SetViewOffset(self:GetEyeOffset(self.Crouched)) end
end

function META:ApplyCrouch(crouched)
	if self.Crouched == crouched then return end

	local body = self:GetRigidBody()

	if not body then return end

	local _, old_height = self:GetDimensions(self.Crouched)
	local new_radius, new_height = self:GetDimensions(crouched)
	local velocity = body:GetVelocity():Copy()
	local angular_velocity = body:GetAngularVelocity():Copy()
	local feet_position = body:GetPosition():Copy() - Vec3(0, old_height * 0.5, 0)
	local new_position = feet_position + Vec3(0, new_height * 0.5, 0)
	self.Crouched = crouched
	body:SetShape(CapsuleShape.New(new_radius, new_height))
	self.Owner.transform:SetPosition(new_position)
	body:SynchronizeFromTransform()
	body.PreviousPosition = body.Position:Copy()
	body:SetVelocity(velocity)
	body:SetAngularVelocity(angular_velocity)

	local camera = self.Owner.camera

	if camera then camera:SetViewOffset(self:GetEyeOffset(crouched)) end
end

function META:EnterWalkMode(reset_velocity)
	self:ConfigureBody(self.Crouched)
	local body = self:GetRigidBody()

	if not body then return end

	body:SetEnabled(true)
	body:SetGrounded(false)
	if body.Wake then body:Wake() else body.Awake = true end
	body.SleepTimer = 0
	self:InitializeFromCamera(reset_velocity ~= false)
end

function META:LeaveWalkMode()
	local body = self:GetRigidBody()
	local camera = self.Owner.camera
	local zero = Vec3()

	if camera then
		self.Owner.transform:SetPosition(camera:GetViewPosition())
		camera:SetViewOffset(zero)
	end

	if body then
		body:SetVelocity(zero)
		body:SetAngularVelocity(zero)
		body:SetEnabled(false)
		body:SetGrounded(false)
	end
end

function META:OnRemove()
	self:LeaveWalkMode()
end

function META:OnCameraModeChanged(mode)
	if mode == "walk" then
		self:EnterWalkMode(true)
	else
		self:LeaveWalkMode()
	end
end

function META:OnCameraInputUpdate(dt, state)
	local transform = self.Owner.transform
	local look = self.Owner.player_input
	local camera = self.Owner.camera
	local body = self:GetRigidBody()

	if not (transform and look) then return end

	if look.Mode == "walk" then
		if not body then return end
		if not self.Initialized then self:InitializeFromCamera(true) end

		self:ApplyCrouch(state.crouching)
		self:ResetBodyRotation()

		if camera then camera:SetViewOffset(self:GetEyeOffset(self.Crouched)) end

		if state.reset_requested then self:InitializeFromCamera(true) end

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

	if camera then camera:SetViewOffset(Vec3()) end

	if not state.mouse_trapped then return end

	local rotation = look:GetRotation()
	local position = transform:GetPosition():Copy()
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

	transform:SetPosition(position + ((forward + right + up) * dt * state.speed_multiplier * self.FlySpeed))
end

return META:Register()