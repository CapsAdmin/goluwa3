local prototype = import("goluwa/prototype.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local default_skin = (
		import.loaded["goluwa/physics.lua"] and
		import.loaded["goluwa/physics.lua"].DefaultSkin
	)
	or
	0.02
local META = prototype.CreateTemplate("rigid_body")
META:GetSet("Enabled", true)
META:GetSet("Shape", nil, {callback = "OnGeometryChanged"})
META:GetSet("MotionType", "dynamic", {callback = "OnMotionTypeChanged"})
META:GetSet("Density", 1, {callback = "RefreshMassProperties"})
META:GetSet("Mass", 1, {callback = "RefreshMassProperties"})
META:GetSet("AutomaticMass", true, {callback = "RefreshMassProperties"})
META:GetSet("GravityScale", 1)
META:GetSet("LinearDamping", 0)
META:GetSet("AngularDamping", 0)
META:GetSet("AirLinearDamping", 0)
META:GetSet("AirAngularDamping", 0)
META:GetSet("CollisionEnabled", true)
META:GetSet("CollisionGroup", 1)
META:GetSet("CollisionMask", -1)
META:GetSet("CollisionMargin", default_skin)
META:GetSet("CollisionProbeDistance", 0.125)
META:GetSet("Friction", 0)
META:GetSet("RollingFriction", 0)
META:GetSet("Restitution", 0)
META:GetSet("FrictionCombineMode", nil)
META:GetSet("RollingFrictionCombineMode", nil)
META:GetSet("RestitutionCombineMode", nil)
META:GetSet("Awake", true)
META:GetSet("CanSleep", true)
META:GetSet("SleepLinearThreshold", 0.15)
META:GetSet("SleepAngularThreshold", 0.15)
META:GetSet("SleepDelay", 0.5)
META:GetSet("MaxLinearSpeed", 240)
META:GetSet("MaxAngularSpeed", 60)
META:GetSet("MinGroundNormalY", 0.2)
META:GetSet("FilterFunction", nil)
META:GetSet("Grounded", false)
META:GetSet("GroundRollingFriction", 0)

local function component_mul(a, b)
	return Vec3(a.x * b.x, a.y * b.y, a.z * b.z)
end

local function zero_vec3()
	return Vec3(0, 0, 0)
end

local function clamp_vec_length(vec, max_length)
	local length = vec:GetLength()

	if not max_length or max_length <= 0 or length <= max_length then return vec end

	return vec / length * max_length
end

local function integrate_rotation(rotation, angular_velocity, dt)
	if angular_velocity:GetLength() == 0 then return rotation:Copy() end

	local delta = Quat(angular_velocity.x, angular_velocity.y, angular_velocity.z, 0) * rotation
	return Quat(
		rotation.x + 0.5 * dt * delta.x,
		rotation.y + 0.5 * dt * delta.y,
		rotation.z + 0.5 * dt * delta.z,
		rotation.w + 0.5 * dt * delta.w
	):GetNormalized()
end

function META:Initialize()
	self.Shape = self.Shape or BoxShape.New(Vec3(1, 1, 1))
	self.Velocity = self.Velocity or Vec3(0, 0, 0)
	self.AngularVelocity = self.AngularVelocity or Vec3(0, 0, 0)
	self.Position = self.Position or Vec3(0, 0, 0)
	self.PreviousPosition = self.PreviousPosition or Vec3(0, 0, 0)
	self.Rotation = self.Rotation or Quat(0, 0, 0, 1)
	self.PreviousRotation = self.PreviousRotation or Quat(0, 0, 0, 1)
	self.GroundNormal = self.GroundNormal or Vec3(0, 1, 0)
	self.InverseMass = self.InverseMass or 0
	self.InverseInertia = self.InverseInertia or Vec3(0, 0, 0)
	self.StepDt = self.StepDt or 0
	self.SleepTimer = self.SleepTimer or 0
	self.AccumulatedForce = self.AccumulatedForce or zero_vec3()
	self.AccumulatedTorque = self.AccumulatedTorque or zero_vec3()
	self:RefreshMassProperties()

	if self.Owner and self.Owner.transform then
		self:SynchronizeFromTransform()
	end
end

function META:OnMotionTypeChanged()
	self:RefreshMassProperties()
end

function META:GetPhysicsShape()
	if not self.Shape then self.Shape = BoxShape.New(Vec3(1, 1, 1)) end

	return self.Shape
end

function META:GetShapeType()
	local shape = self:GetPhysicsShape()
	return shape and shape.GetTypeName and shape:GetTypeName() or "unknown"
end

function META:OnAdd(entity)
	self.Owner = entity
	local controller = entity.kinematic_controller

	if controller and self:GetMotionType() ~= "kinematic" then
		self:SetMotionType("kinematic")
	end

	if entity.transform then self:SynchronizeFromTransform() end
end

function META:OnGeometryChanged()
	self.CollisionLocalPoints = nil
	self.SupportLocalPoints = nil
	local shape = self:GetPhysicsShape()

	if shape and shape.OnBodyGeometryChanged then
		shape:OnBodyGeometryChanged(self)
	end

	self:RefreshMassProperties()
end

local function get_bounds_from_points(points)
	if not points or not points[1] then return nil end

	local min_bounds = Vec3(math.huge, math.huge, math.huge)
	local max_bounds = Vec3(-math.huge, -math.huge, -math.huge)

	for _, point in ipairs(points) do
		min_bounds.x = math.min(min_bounds.x, point.x)
		min_bounds.y = math.min(min_bounds.y, point.y)
		min_bounds.z = math.min(min_bounds.z, point.z)
		max_bounds.x = math.max(max_bounds.x, point.x)
		max_bounds.y = math.max(max_bounds.y, point.y)
		max_bounds.z = math.max(max_bounds.z, point.z)
	end

	return min_bounds, max_bounds
end

function META:GetResolvedConvexHull()
	local shape = self:GetPhysicsShape()

	if not (shape and shape.GetResolvedHull) then return nil end

	return shape:GetResolvedHull(self)
end

function META:RefreshMassProperties()
	local shape = self:GetPhysicsShape()
	local mass, inverse_inertia = shape:GetMassProperties(self)
	self.ComputedMass = mass

	if mass <= 0 then
		self.InverseMass = 0
		self.InverseInertia = Vec3(0, 0, 0)
		return
	end

	self.InverseMass = 1 / mass
	self.InverseInertia = inverse_inertia or Vec3(0, 0, 0)
end

function META:GetBody()
	return self
end

function META:GetKinematicController()
	return self.Owner and self.Owner.kinematic_controller or nil
end

function META:HasKinematicController()
	return self:GetKinematicController() ~= nil
end

function META:GetVelocity()
	return self.Velocity
end

function META:SetVelocity(vec)
	self.Velocity = vec:Copy()

	if
		self:HasSolverMass() and
		vec:GetLength() > math.max(self.SleepLinearThreshold or 0, 0)
	then
		self:Wake()
	end
end

function META:GetAngularVelocity()
	return self.AngularVelocity
end

function META:SetAngularVelocity(vec)
	self.AngularVelocity = vec:Copy()

	if
		self:HasSolverMass() and
		vec:GetLength() > math.max(self.SleepAngularThreshold or 0, 0)
	then
		self:Wake()
	end
end

function META:GetPosition()
	return self.Position
end

function META:SetPosition(vec)
	self.Position = vec:Copy()

	if self:HasSolverMass() then self:Wake() end
end

function META:GetPreviousPosition()
	return self.PreviousPosition
end

function META:GetRotation()
	return self.Rotation
end

function META:SetRotation(quat)
	self.Rotation = quat:Copy()

	if self:HasSolverMass() then self:Wake() end
end

function META:GetPreviousRotation()
	return self.PreviousRotation
end

function META:GetGroundNormal()
	return self.GroundNormal
end

function META:SetGroundNormal(vec)
	self.GroundNormal = vec:Copy()
end

function META:SetGrounded(grounded)
	self.Grounded = grounded

	if not grounded then self.GroundRollingFriction = 0 end
end

function META:GetGrounded()
	return self.Grounded
end

function META:GetAccumulatedForce()
	return self.AccumulatedForce
end

function META:GetAccumulatedTorque()
	return self.AccumulatedTorque
end

function META:ClearAccumulators()
	self.AccumulatedForce = zero_vec3()
	self.AccumulatedTorque = zero_vec3()
end

function META:GetAngularVelocityDelta(world_impulse)
	local local_impulse = self.Rotation:GetConjugated():VecMul(world_impulse)
	local local_delta = component_mul(local_impulse, self.InverseInertia)
	return self.Rotation:VecMul(local_delta)
end

function META:ApplyAngularImpulse(world_impulse)
	if not self:HasSolverMass() then return self end

	self:Wake()
	self.AngularVelocity = self.AngularVelocity + self:GetAngularVelocityDelta(world_impulse)
	return self
end

function META:ApplyImpulse(impulse, world_pos)
	if not self:HasSolverMass() then return self end

	self:Wake()
	self.Velocity = self.Velocity + impulse * self.InverseMass

	if world_pos then
		self:ApplyAngularImpulse((world_pos - self.Position):GetCross(impulse))
	end

	return self
end

function META:ApplyTorque(torque)
	if not self:HasSolverMass() then return self end

	self:Wake()
	self.AccumulatedTorque = self.AccumulatedTorque + torque
	return self
end

function META:ApplyForce(force, world_pos)
	if not self:HasSolverMass() then return self end

	self:Wake()
	self.AccumulatedForce = self.AccumulatedForce + force

	if world_pos then
		self:ApplyTorque((world_pos - self.Position):GetCross(force))
	end

	return self
end

META.AddForce = META.ApplyForce
META.AddTorque = META.ApplyTorque
META.AddImpulse = META.ApplyImpulse

function META:Wake()
	if not self:HasSolverMass() then return end

	self.Awake = true
	self.SleepTimer = 0
end

function META:Sleep()
	if not self:HasSolverMass() then return end

	self.Awake = false
	self.SleepTimer = 0
	self.Velocity = Vec3(0, 0, 0)
	self.AngularVelocity = Vec3(0, 0, 0)
	self.PreviousPosition = self.Position:Copy()
	self.PreviousRotation = self.Rotation:Copy()
end

function META:UpdateSleepState(dt)
	if not self:HasSolverMass() or not self.CanSleep then return end

	if not self.Awake then
		self.Velocity = Vec3(0, 0, 0)
		self.AngularVelocity = Vec3(0, 0, 0)
		self.PreviousPosition = self.Position:Copy()
		self.PreviousRotation = self.Rotation:Copy()
		return
	end

	if
		self.Velocity:GetLength() <= self.SleepLinearThreshold and
		self.AngularVelocity:GetLength() <= self.SleepAngularThreshold
	then
		self.SleepTimer = self.SleepTimer + dt

		if self.SleepTimer >= self.SleepDelay then self:Sleep() end
	else
		self.SleepTimer = 0
	end
end

function META:GetHalfExtents()
	return self:GetPhysicsShape():GetHalfExtents(self)
end

function META:IsStatic()
	return self.MotionType == "static"
end

function META:IsKinematic()
	return self.MotionType == "kinematic"
end

function META:IsDynamic()
	return self.MotionType == "dynamic"
end

function META:HasSolverMass()
	return self:IsDynamic() and self.InverseMass > 0
end

function META:IsSolverImmovable()
	return not self:HasSolverMass()
end

function META:SynchronizeFromTransform()
	if not (self.Owner and self.Owner.transform) then return end

	local position = self.Owner.transform:GetPosition():Copy()
	local rotation = self.Owner.transform:GetRotation():Copy()

	if self:IsKinematic() then
		self.PreviousPosition = self.Position and self.Position:Copy() or position:Copy()
		self.PreviousRotation = self.Rotation and self.Rotation:Copy() or rotation:Copy()
	else
		self.PreviousPosition = position:Copy()
		self.PreviousRotation = rotation:Copy()
	end

	self.Position = position
	self.Rotation = rotation
end

function META:WriteToTransform()
	if not (self.Owner and self.Owner.transform) then return end

	self.Owner.transform:SetPosition(self.Position:Copy())
	self.Owner.transform:SetRotation(self.Rotation:Copy())
end

function META:LocalToWorld(local_pos, position, rotation)
	position = position or self.Position
	rotation = rotation or self.Rotation
	return position + rotation:VecMul(local_pos)
end

function META:GeometryLocalToWorld(local_pos, position, rotation)
	return self:GetPhysicsShape():GeometryLocalToWorld(self, local_pos, position, rotation)
end

function META:WorldToLocal(world_pos, position, rotation)
	position = position or self.Position
	rotation = rotation or self.Rotation
	return rotation:GetConjugated():VecMul(world_pos - position)
end

function META:GetBroadphaseAABB(position, rotation)
	return self:GetPhysicsShape():GetBroadphaseAABB(self, position, rotation)
end

function META:Integrate(dt, gravity)
	self.StepDt = dt
	self.PreviousPosition = self.Position:Copy()
	self.PreviousRotation = self.Rotation:Copy()

	if self:IsKinematic() then return end

	if not self:HasSolverMass() or not self.Awake then return end

	local velocity = self.Velocity + gravity * (
			self.GravityScale * dt
		) + self.AccumulatedForce * (
			self.InverseMass * dt
		)
	local angular_velocity = self.AngularVelocity + self:GetAngularVelocityDelta(self.AccumulatedTorque * dt)
	self.Velocity = clamp_vec_length(velocity, self.MaxLinearSpeed)
	self.AngularVelocity = clamp_vec_length(angular_velocity, self.MaxAngularSpeed)
	self.Position = self.Position + self.Velocity * dt
	self.Rotation = integrate_rotation(self.Rotation, self.AngularVelocity, dt)
end

function META:UpdateVelocities(dt)
	if self:IsKinematic() then
		self.Velocity = (self.Position - self.PreviousPosition) / dt
		local delta = (self.Rotation * self.PreviousRotation:GetConjugated()):GetNormalized()
		self.AngularVelocity = Vec3(delta.x * 2 / dt, delta.y * 2 / dt, delta.z * 2 / dt)

		if delta.w < 0 then self.AngularVelocity = self.AngularVelocity * -1 end

		self.PreviousPosition = self.Position:Copy()
		self.PreviousRotation = self.Rotation:Copy()
		return
	end

	if not self:HasSolverMass() then
		self.Velocity = Vec3(0, 0, 0)
		self.AngularVelocity = Vec3(0, 0, 0)
		return
	end

	if not self.Awake then
		self.Velocity = Vec3(0, 0, 0)
		self.AngularVelocity = Vec3(0, 0, 0)
		self.PreviousPosition = self.Position:Copy()
		self.PreviousRotation = self.Rotation:Copy()
		return
	end

	self.Velocity = (self.Position - self.PreviousPosition) / dt
	local delta = (self.Rotation * self.PreviousRotation:GetConjugated()):GetNormalized()
	self.AngularVelocity = Vec3(delta.x * 2 / dt, delta.y * 2 / dt, delta.z * 2 / dt)

	if delta.w < 0 then self.AngularVelocity = self.AngularVelocity * -1 end

	if self.Grounded then
		local normal_speed = self.Velocity:Dot(self.GroundNormal)

		if normal_speed < 0 then
			self.Velocity = self.Velocity - self.GroundNormal * normal_speed
		end

		self:GetPhysicsShape():OnGroundedVelocityUpdate(self, dt)
	end

	local linear_damping_value = self.Grounded and self.LinearDamping or self.AirLinearDamping
	local angular_damping_value = self.Grounded and self.AngularDamping or self.AirAngularDamping
	local linear_damping = math.max(1 - linear_damping_value * dt, 0)
	local angular_damping = math.max(1 - angular_damping_value * dt, 0)
	self.Velocity = clamp_vec_length(self.Velocity * linear_damping, self.MaxLinearSpeed)
	self.AngularVelocity = clamp_vec_length(self.AngularVelocity * angular_damping, self.MaxAngularSpeed)
end

function META:GetInverseMassAlong(normal, pos)
	if not self:HasSolverMass() then return 0 end

	local tangent = normal:Copy()

	if pos then tangent = (pos - self.Position):GetCross(normal) end

	tangent = self.Rotation:GetConjugated():VecMul(tangent)
	local angular = tangent.x * tangent.x * self.InverseInertia.x + tangent.y * tangent.y * self.InverseInertia.y + tangent.z * tangent.z * self.InverseInertia.z

	if pos then angular = angular + self.InverseMass end

	return angular
end

function META:_ApplyCorrection(correction, pos)
	if not self:HasSolverMass() then return end

	self.Position = self.Position + correction * self.InverseMass

	if not pos then return end

	local angular = (pos - self.Position):GetCross(correction)
	angular = self.Rotation:GetConjugated():VecMul(angular)
	angular = component_mul(angular, self.InverseInertia)
	angular = self.Rotation:VecMul(angular)
	local delta = Quat(angular.x, angular.y, angular.z, 0) * self.Rotation
	self.Rotation = Quat(
		self.Rotation.x + 0.5 * delta.x,
		self.Rotation.y + 0.5 * delta.y,
		self.Rotation.z + 0.5 * delta.z,
		self.Rotation.w + 0.5 * delta.w
	):GetNormalized()
end

function META:ApplyCorrection(compliance, correction, pos, other_body, other_pos, dt)
	local length = correction:GetLength()

	if length == 0 then return 0 end

	dt = dt or self.StepDt

	if not dt or dt <= 0 then dt = 1 / 60 end

	local normal = correction / length
	local inverse_mass = self:GetInverseMassAlong(normal, pos)

	if other_body then
		inverse_mass = inverse_mass + other_body:GetInverseMassAlong(normal, other_pos)
	end

	if inverse_mass == 0 then return 0 end

	local alpha = (compliance or 0) / (dt * dt)
	local lambda = -length / (inverse_mass + alpha)
	local impulse = normal * -lambda
	self:_ApplyCorrection(impulse, pos)

	if other_body then other_body:_ApplyCorrection(impulse * -1, other_pos) end

	return lambda / (dt * dt)
end

function META:BuildCollisionLocalPoints()
	return self:GetPhysicsShape():BuildCollisionLocalPoints(self)
end

function META:GetCollisionLocalPoints()
	if not self.CollisionLocalPoints then
		self.CollisionLocalPoints = self:BuildCollisionLocalPoints()
	end

	return self.CollisionLocalPoints
end

function META:BuildSupportLocalPoints()
	return self:GetPhysicsShape():BuildSupportLocalPoints(self)
end

function META:GetSupportLocalPoints()
	if not self.SupportLocalPoints then
		self.SupportLocalPoints = self:BuildSupportLocalPoints()
	end

	return self.SupportLocalPoints
end

return META:Register()