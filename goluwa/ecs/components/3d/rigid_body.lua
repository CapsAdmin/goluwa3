local prototype = import("goluwa/prototype.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local ConvexShape = import("goluwa/physics/shapes/convex.lua")
local Collider = import("goluwa/physics/collider.lua")
local default_skin = (
		import.loaded["goluwa/physics.lua"] and
		import.loaded["goluwa/physics.lua"].DefaultSkin
	)
	or
	0.02
local META = prototype.CreateTemplate("rigid_body")
META:GetSet("Enabled", true)
META:GetSet("Shape", nil, {callback = "OnGeometryChanged"})
META:GetSet("Shapes", nil, {callback = "OnGeometryChanged"})
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
META:GetSet("GroundEntity", nil)
META:GetSet("GroundBody", nil)

local function component_mul(a, b)
	return Vec3(a.x * b.x, a.y * b.y, a.z * b.z)
end

local function zero_vec3()
	return Vec3(0, 0, 0)
end

local function identity_quat()
	return Quat(0, 0, 0, 1)
end

local function copy_position(position)
	if position and position.Copy then return position:Copy() end

	return zero_vec3()
end

local function copy_rotation(rotation)
	if rotation and rotation.Copy then return rotation:Copy() end

	return identity_quat()
end

local function inverse_to_inertia(value)
	if not value or value <= 0 then return 0 end

	return 1 / value
end

local function get_rotated_inertia_diagonal(rotation, inertia)
	local axis_x = rotation:VecMul(Vec3(1, 0, 0))
	local axis_y = rotation:VecMul(Vec3(0, 1, 0))
	local axis_z = rotation:VecMul(Vec3(0, 0, 1))
	return Vec3(
		inertia.x * axis_x.x * axis_x.x + inertia.y * axis_y.x * axis_y.x + inertia.z * axis_z.x * axis_z.x,
		inertia.x * axis_x.y * axis_x.y + inertia.y * axis_y.y * axis_y.y + inertia.z * axis_z.y * axis_z.y,
		inertia.x * axis_x.z * axis_x.z + inertia.y * axis_y.z * axis_y.z + inertia.z * axis_z.z * axis_z.z
	)
end

local function is_shape_definition(value)
	return type(value) == "table" and
		(
			value.Shape ~= nil or
			value.shape ~= nil or
			value.Position ~= nil or
			value.position ~= nil or
			value.Rotation ~= nil or
			value.rotation ~= nil or
			value.ConvexHull ~= nil
		)
end

local function get_shape_from_definition(data)
	local shape = data.Shape or data.shape

	if not shape and data.ConvexHull then
		shape = ConvexShape.New(data.ConvexHull)
	end

	return shape
end

local function append_shape_entry(entries, entry, parent_position, parent_rotation)
	parent_position = parent_position or zero_vec3()
	parent_rotation = parent_rotation or identity_quat()
	local data = is_shape_definition(entry) and entry or {Shape = entry}
	local shape = get_shape_from_definition(data)
	local local_position = copy_position(data.Position or data.position)
	local local_rotation = copy_rotation(data.Rotation or data.rotation)
	local combined_position = parent_position + parent_rotation:VecMul(local_position)
	local combined_rotation = (parent_rotation * local_rotation):GetNormalized()

	if
		shape and
		shape.GetTypeName and
		shape:GetTypeName() == "compound" and
		shape.GetChildren
	then
		for _, child in ipairs(shape:GetChildren()) do
			append_shape_entry(entries, child, combined_position, combined_rotation)
		end

		return
	end

	entries[#entries + 1] = {
		Shape = shape,
		Position = combined_position,
		Rotation = combined_rotation,
		Density = data.Density,
		Mass = data.Mass,
		AutomaticMass = data.AutomaticMass,
		CollisionGroup = data.CollisionGroup,
		CollisionMask = data.CollisionMask,
		CollisionMargin = data.CollisionMargin,
		CollisionProbeDistance = data.CollisionProbeDistance,
		Friction = data.Friction,
		RollingFriction = data.RollingFriction,
		Restitution = data.Restitution,
		FrictionCombineMode = data.FrictionCombineMode,
		RollingFrictionCombineMode = data.RollingFrictionCombineMode,
		RestitutionCombineMode = data.RestitutionCombineMode,
		FilterFunction = data.FilterFunction,
		MinGroundNormalY = data.MinGroundNormalY,
	}
end

local function build_collider_entries(body)
	local entries = {}
	local shapes = body.Shapes

	if shapes and shapes[1] then
		for _, entry in ipairs(shapes) do
			append_shape_entry(entries, entry)
		end
	elseif body.Shape then
		append_shape_entry(entries, body.Shape)
	end

	if not entries[1] then
		entries[1] = {
			Shape = BoxShape.New(Vec3(1, 1, 1)),
			Position = zero_vec3(),
			Rotation = identity_quat(),
		}
	end

	return entries
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
	self.Colliders = nil
	self:RebuildColliders()
	self:RefreshMassProperties()

	if self.Owner and self.Owner.transform then
		self:SynchronizeFromTransform()
	end
end

function META:OnMotionTypeChanged()
	self:RefreshMassProperties()
end

function META:GetOwner()
	return self.Owner
end

function META:RebuildColliders()
	local colliders = {}

	for index, entry in ipairs(build_collider_entries(self)) do
		colliders[index] = Collider.New(self, entry, index):InvalidateGeometry()
	end

	self.Colliders = colliders
	self.CollisionLocalPoints = nil
	self.SupportLocalPoints = nil
	self.LocalBounds = nil
	return colliders
end

function META:GetColliders()
	if not self.Colliders or not self.Colliders[1] then
		self:RebuildColliders()
	end

	return self.Colliders
end

function META:GetPhysicsShape()
	local colliders = self:GetColliders()

	if #colliders ~= 1 then return nil end

	return colliders[1]:GetPhysicsShape()
end

function META:GetShapeType()
	local colliders = self:GetColliders()

	if #colliders ~= 1 then return "compound" end

	return colliders[1]:GetShapeType()
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
	self:RebuildColliders()
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
	local colliders = self:GetColliders()

	if #colliders ~= 1 then return nil end

	return colliders[1]:GetResolvedConvexHull()
end

function META:RefreshMassProperties()
	local computed_mass = 0
	local inertia = Vec3(0, 0, 0)
	local has_collider_inertia = false

	for _, collider in ipairs(self:GetColliders()) do
		local collider_mass, collider_inverse_inertia = collider:GetPhysicsShape():GetMassProperties(collider)

		if collider_mass and collider_mass > 0 then
			computed_mass = computed_mass + collider_mass
			has_collider_inertia = true
			local collider_inertia = Vec3(
				inverse_to_inertia(collider_inverse_inertia and collider_inverse_inertia.x or 0),
				inverse_to_inertia(collider_inverse_inertia and collider_inverse_inertia.y or 0),
				inverse_to_inertia(collider_inverse_inertia and collider_inverse_inertia.z or 0)
			)
			local rotated = get_rotated_inertia_diagonal(collider:GetLocalRotation(), collider_inertia)
			local position = collider:GetLocalPosition()
			inertia.x = inertia.x + rotated.x + collider_mass * (
					position.y * position.y + position.z * position.z
				)
			inertia.y = inertia.y + rotated.y + collider_mass * (
					position.x * position.x + position.z * position.z
				)
			inertia.z = inertia.z + rotated.z + collider_mass * (
					position.x * position.x + position.y * position.y
				)
		end
	end

	local mass = self:GetMass()

	if not self:IsDynamic() then
		mass = 0
	elseif self:GetAutomaticMass() then
		mass = computed_mass
	end

	self.ComputedMass = computed_mass

	if mass <= 0 then
		self.InverseMass = 0
		self.InverseInertia = Vec3(0, 0, 0)
		return
	end

	self.InverseMass = 1 / mass

	if has_collider_inertia and computed_mass > 0 then
		if not self:GetAutomaticMass() and mass ~= computed_mass then
			inertia = inertia * (mass / computed_mass)
		end

		self.InverseInertia = Vec3(
			inertia.x > 0 and 1 / inertia.x or 0,
			inertia.y > 0 and 1 / inertia.y or 0,
			inertia.z > 0 and 1 / inertia.z or 0
		)
		return
	end

	local min_bounds, max_bounds = get_bounds_from_points(self:GetCollisionLocalPoints())

	if not (min_bounds and max_bounds) then
		self.InverseInertia = Vec3(0, 0, 0)
		return
	end

	local size = max_bounds - min_bounds
	local sx, sy, sz = size.x, size.y, size.z
	local ix = (1 / 12) * mass * (sy * sy + sz * sz)
	local iy = (1 / 12) * mass * (sx * sx + sz * sz)
	local iz = (1 / 12) * mass * (sx * sx + sy * sy)
	self.InverseInertia = Vec3(ix > 0 and 1 / ix or 0, iy > 0 and 1 / iy or 0, iz > 0 and 1 / iz or 0)
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

	if not grounded then
		self.GroundRollingFriction = 0
		self.GroundEntity = nil
		self.GroundBody = nil
	end
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
	local bounds = self.LocalBounds

	if not bounds then
		local min_bounds, max_bounds = get_bounds_from_points(self:GetCollisionLocalPoints())

		if not (min_bounds and max_bounds) then return Vec3(0.5, 0.5, 0.5) end

		bounds = {min = min_bounds, max = max_bounds}
		self.LocalBounds = bounds
	end

	return (bounds.max - bounds.min) * 0.5
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
	return self:LocalToWorld(local_pos, position, rotation)
end

function META:WorldToLocal(world_pos, position, rotation)
	position = position or self.Position
	rotation = rotation or self.Rotation
	return rotation:GetConjugated():VecMul(world_pos - position)
end

function META:GetBroadphaseAABB(position, rotation)
	position = position or self.Position
	rotation = rotation or self.Rotation
	local min_bounds = Vec3(math.huge, math.huge, math.huge)
	local max_bounds = Vec3(-math.huge, -math.huge, -math.huge)
	local has_bounds = false

	for _, collider in ipairs(self:GetColliders()) do
		local collider_position = position + rotation:VecMul(collider:GetLocalPosition())
		local collider_rotation = (rotation * collider:GetLocalRotation()):GetNormalized()
		local bounds = collider:GetBroadphaseAABB(collider_position, collider_rotation)
		min_bounds.x = math.min(min_bounds.x, bounds.min_x)
		min_bounds.y = math.min(min_bounds.y, bounds.min_y)
		min_bounds.z = math.min(min_bounds.z, bounds.min_z)
		max_bounds.x = math.max(max_bounds.x, bounds.max_x)
		max_bounds.y = math.max(max_bounds.y, bounds.max_y)
		max_bounds.z = math.max(max_bounds.z, bounds.max_z)
		has_bounds = true
	end

	if not has_bounds then
		local half = Vec3(0.5, 0.5, 0.5)
		return AABB(
			position.x - half.x,
			position.y - half.y,
			position.z - half.z,
			position.x + half.x,
			position.y + half.y,
			position.z + half.z
		)
	end

	return AABB(
		min_bounds.x,
		min_bounds.y,
		min_bounds.z,
		max_bounds.x,
		max_bounds.y,
		max_bounds.z
	)
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

		for _, collider in ipairs(self:GetColliders()) do
			collider:GetPhysicsShape():OnGroundedVelocityUpdate(self, dt)
		end
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
	local points = {}

	for _, collider in ipairs(self:GetColliders()) do
		for _, point in ipairs(collider:GetCollisionLocalPoints() or {}) do
			points[#points + 1] = collider:GetLocalPosition() + collider:GetLocalRotation():VecMul(point)
		end
	end

	return points
end

function META:GetCollisionLocalPoints()
	if not self.CollisionLocalPoints then
		self.CollisionLocalPoints = self:BuildCollisionLocalPoints()
	end

	return self.CollisionLocalPoints
end

function META:BuildSupportLocalPoints()
	local points = {}

	for _, collider in ipairs(self:GetColliders()) do
		for _, point in ipairs(collider:GetSupportLocalPoints() or {}) do
			points[#points + 1] = collider:GetLocalPosition() + collider:GetLocalRotation():VecMul(point)
		end
	end

	return points
end

function META:GetSupportLocalPoints()
	if not self.SupportLocalPoints then
		self.SupportLocalPoints = self:BuildSupportLocalPoints()
	end

	return self.SupportLocalPoints
end

return META:Register()