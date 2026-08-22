local objects = import("goluwa/objects/objects.lua")
local bit = require("bit")
local physics_constants = import("goluwa/physics/constants.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Matrix33 = import("goluwa/structs/matrix33.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Collider = import("goluwa/physics/collider.lua")
local Entity = import("goluwa/entities/entity.lua")
local stats = import("goluwa/physics/stats.lua")
local RigidBody = objects.CreateTemplate("rigid_body")
RigidBody.Physics = nil

do
	RigidBody:GetSet("Shape", nil, {callback = "OnGeometryChanged"})
	RigidBody:GetSet("Shapes", nil, {callback = "OnGeometryChanged"})
	RigidBody:GetSet("MotionType", "dynamic", {callback = "OnMotionTypeChanged"})
	RigidBody:GetSet("Density", 1, {callback = "RefreshMassProperties"})
	RigidBody:GetSet("Mass", 1, {callback = "RefreshMassProperties"})
	RigidBody:GetSet("AutomaticMass", true, {callback = "RefreshMassProperties"})
	RigidBody:GetSet("GravityScale", 1)
	RigidBody:GetSet("LinearDamping", 0)
	RigidBody:GetSet("AngularDamping", 0)
	RigidBody:GetSet("AirLinearDamping", 0)
	RigidBody:GetSet("AirAngularDamping", 0)
	RigidBody:GetSet("CollisionEnabled", true)
	RigidBody:GetSet("WorldGeometry", false)
	RigidBody:GetSet("CollisionGroup", 1)
	RigidBody:GetSet("CollisionMask", -1)
	RigidBody:GetSet("CCD", false)
	RigidBody:GetSet("AutoCCD", true)
	RigidBody:GetSet("AutoCCDThreshold", 0.5)
	RigidBody:GetSet("CollisionMargin", physics_constants.DEFAULT_COLLISION_MARGIN)
	RigidBody:GetSet("CollisionProbeDistance", 0.125)
	RigidBody:GetSet("Friction", 0)
	RigidBody:GetSet("StaticFriction", nil)
	RigidBody:GetSet("RollingFriction", 0)
	RigidBody:GetSet("Restitution", 0)
	RigidBody:GetSet("FrictionCombineMode", nil)
	RigidBody:GetSet("StaticFrictionCombineMode", nil)
	RigidBody:GetSet("RollingFrictionCombineMode", nil)
	RigidBody:GetSet("RestitutionCombineMode", nil)
	RigidBody:GetSet("Awake", true)
	RigidBody:GetSet("CanSleep", true)
	RigidBody:GetSet("SleepLinearThreshold", 0.15)
	RigidBody:GetSet("SleepAngularThreshold", 0.15)
	RigidBody:GetSet("SleepDelay", 0.5)
	RigidBody:GetSet("MaxLinearSpeed", 240)
	RigidBody:GetSet("MaxAngularSpeed", 60)
	RigidBody:GetSet("MinGroundNormalY", 0.2)
	RigidBody:GetSet("FilterFunction", nil)
	RigidBody:GetSet("Grounded", false)
	RigidBody:GetSet("GroundRollingFriction", 0)
	RigidBody:GetSet("GroundEntity", nil)
	RigidBody:GetSet("GroundBody", nil)

	local function new_zero_matrix()
		return Matrix33():SetZero()
	end

	local function get_rotation_matrix(rotation, out)
		out = out or Matrix33()
		out:SetRotation(rotation or Quat():Identity())
		return out
	end

	local function rotate_inertia_tensor(rotation, inertia_tensor, out)
		if not inertia_tensor then return new_zero_matrix() end

		local rotation_matrix = get_rotation_matrix(rotation)
		local transposed = rotation_matrix:GetTransposed(Matrix33())
		local rotated = rotation_matrix:GetMultiplied(inertia_tensor, out or Matrix33())
		return rotated:Multiply(transposed)
	end

	local function add_parallel_axis_term(inertia_tensor, mass, position)
		if not (mass and mass > 0 and position) then return inertia_tensor end

		local x = position.x
		local y = position.y
		local z = position.z
		inertia_tensor.m00 = inertia_tensor.m00 + mass * (y * y + z * z)
		inertia_tensor.m01 = inertia_tensor.m01 - mass * x * y
		inertia_tensor.m02 = inertia_tensor.m02 - mass * x * z
		inertia_tensor.m10 = inertia_tensor.m10 - mass * x * y
		inertia_tensor.m11 = inertia_tensor.m11 + mass * (x * x + z * z)
		inertia_tensor.m12 = inertia_tensor.m12 - mass * y * z
		inertia_tensor.m20 = inertia_tensor.m20 - mass * x * z
		inertia_tensor.m21 = inertia_tensor.m21 - mass * y * z
		inertia_tensor.m22 = inertia_tensor.m22 + mass * (x * x + y * y)
		return inertia_tensor
	end

	local function get_box_inertia_tensor(mass, size)
		local sx, sy, sz = size.x, size.y, size.z
		local ix = (1 / 12) * mass * (sy * sy + sz * sz)
		local iy = (1 / 12) * mass * (sx * sx + sz * sz)
		local iz = (1 / 12) * mass * (sx * sx + sy * sy)
		return Matrix33():SetDiagonal(ix, iy, iz)
	end

	local function get_inverse_tensor(tensor)
		return tensor:GetInverse(Matrix33())
	end

	local ROTATION_INTEGRATION_DELTA = Quat()
	local TEMPORARY_TORQUE = Vec3()

	local function clamp_vec_length(vec, max_length)
		local length = vec:GetLength()

		if not max_length or max_length <= 0 or length <= max_length then return vec end

		vec:Scale(max_length / length)
		return vec
	end

	local function integrate_rotation(rotation, angular_velocity, dt)
		if angular_velocity:GetLengthSquared() == 0 then return rotation end

		local delta = ROTATION_INTEGRATION_DELTA
		delta.x, delta.y, delta.z, delta.w = angular_velocity.x, angular_velocity.y, angular_velocity.z, 0
		Quat.SetMul(delta, delta, rotation)
		local half_dt = 0.5 * dt
		rotation.x = rotation.x + half_dt * delta.x
		rotation.y = rotation.y + half_dt * delta.y
		rotation.z = rotation.z + half_dt * delta.z
		rotation.w = rotation.w + half_dt * delta.w
		rotation:Normalize()
		return rotation
	end

	local function build_ground_support_basis(normal)
		local tangent

		if math.abs(normal.x) < 0.8 then
			tangent = normal:GetCross(Vec3(1, 0, 0))
		else
			tangent = normal:GetCross(Vec3(0, 1, 0))
		end

		if tangent:GetLength() <= physics_constants.EPSILON then
			tangent = normal:GetCross(Vec3(0, 0, 1))
		end

		if tangent:GetLength() <= physics_constants.EPSILON then return nil, nil end

		tangent = tangent:GetNormalized()
		return tangent, normal:GetCross(tangent):GetNormalized()
	end

	function RigidBody:Initialize()
		self.Velocity = self.Velocity or Vec3(0, 0, 0)
		self.AngularVelocity = self.AngularVelocity or Vec3(0, 0, 0)
		self.Position = self.Position or Vec3(0, 0, 0)
		self.PreviousPosition = self.PreviousPosition or Vec3(0, 0, 0)
		self.Rotation = self.Rotation or Quat(0, 0, 0, 1)
		self.PreviousRotation = self.PreviousRotation or Quat(0, 0, 0, 1)
		self.GroundNormal = self.GroundNormal or Vec3(0, 1, 0)
		self.InverseMass = self.InverseMass or 0
		self.InertiaTensor = self.InertiaTensor or new_zero_matrix()
		self.InverseInertiaTensor = self.InverseInertiaTensor or new_zero_matrix()
		self.StepDt = self.StepDt or 0
		self.SleepTimer = self.SleepTimer or 0
		self.AccumulatedForce = self.AccumulatedForce or Vec3()
		self.AccumulatedTorque = self.AccumulatedTorque or Vec3()
		self:ResetGroundSupport()
		self.Colliders = nil
		self:RebuildColliders()
		self:RefreshMassProperties()

		if self.Owner and self.Owner.transform then
			self:SynchronizeFromTransform()
		end
	end

	function RigidBody:OnMotionTypeChanged()
		self:RefreshMassProperties()
	end

	function RigidBody:GetOwner()
		return self.Owner
	end

	function RigidBody:ResetGroundSupport()
		self.GroundSupportCount = 0
		self.GroundSupportNormal = nil
		self.GroundSupportPoint = nil
		self.GroundSupportTangent = nil
		self.GroundSupportBitangent = nil
		self.GroundSupportMinU = math.huge
		self.GroundSupportMaxU = -math.huge
		self.GroundSupportMinV = math.huge
		self.GroundSupportMaxV = -math.huge
	end

	function RigidBody:AccumulateGroundSupportContact(normal, point)
		if not (normal and point) then return end

		if self.GroundSupportCount == 0 or not self.GroundSupportNormal then
			local tangent, bitangent = build_ground_support_basis(normal)

			if not tangent or not bitangent then return end

			self.GroundSupportNormal = normal:Copy()
			self.GroundSupportTangent = tangent
			self.GroundSupportBitangent = bitangent
			self.GroundSupportPoint = point:Copy()
		end

		local origin = self.GroundSupportPoint or point
		local delta = point - origin
		local u = delta:Dot(self.GroundSupportTangent)
		local v = delta:Dot(self.GroundSupportBitangent)
		self.GroundSupportMinU = math.min(self.GroundSupportMinU, u)
		self.GroundSupportMaxU = math.max(self.GroundSupportMaxU, u)
		self.GroundSupportMinV = math.min(self.GroundSupportMinV, v)
		self.GroundSupportMaxV = math.max(self.GroundSupportMaxV, v)
		self.GroundSupportCount = self.GroundSupportCount + 1
	end

	function RigidBody:GetGroundSupportMetrics()
		local count = self.GroundSupportCount or 0

		if count <= 0 then
			return {
				count = 0,
				min_u = 0,
				max_u = 0,
				min_v = 0,
				max_v = 0,
				span_u = 0,
				span_v = 0,
				max_span = 0,
				normal = nil,
				point = nil,
			}
		end

		local span_u = math.max(0, (self.GroundSupportMaxU or 0) - (self.GroundSupportMinU or 0))
		local span_v = math.max(0, (self.GroundSupportMaxV or 0) - (self.GroundSupportMinV or 0))
		return {
			count = count,
			min_u = self.GroundSupportMinU or 0,
			max_u = self.GroundSupportMaxU or 0,
			min_v = self.GroundSupportMinV or 0,
			max_v = self.GroundSupportMaxV or 0,
			span_u = span_u,
			span_v = span_v,
			max_span = math.max(span_u, span_v),
			normal = self.GroundSupportNormal,
			point = self.GroundSupportPoint,
		}
	end

	function RigidBody:GetGroundSupportProjectionMetrics()
		local support = self:GetGroundSupportMetrics()

		if support.count <= 0 or not support.point then return support end

		local tangent = self.GroundSupportTangent
		local bitangent = self.GroundSupportBitangent

		if not tangent or not bitangent then return support end

		local delta = self.Position - support.point
		local projected_u = delta:Dot(tangent)
		local projected_v = delta:Dot(bitangent)
		local clamped_u = math.max(support.min_u, math.min(support.max_u, projected_u))
		local clamped_v = math.max(support.min_v, math.min(support.max_v, projected_v))
		local overhang_u = projected_u - clamped_u
		local overhang_v = projected_v - clamped_v
		local overhang = tangent * overhang_u + bitangent * overhang_v
		support.projected_u = projected_u
		support.projected_v = projected_v
		support.clamped_u = clamped_u
		support.clamped_v = clamped_v
		support.overhang_u = overhang_u
		support.overhang_v = overhang_v
		support.overhang = overhang
		support.overhang_length = overhang:GetLength()
		support.tangent = tangent
		support.bitangent = bitangent
		return support
	end

	function RigidBody:IsGroundSupportStable()
		if not self:GetGrounded() then
			return false, self:GetGroundSupportProjectionMetrics()
		end

		local support = self:GetGroundSupportProjectionMetrics()

		if support.count <= 0 or not support.point then return false, support end

		local tolerance = math.max(
			(self:GetCollisionMargin() or 0) * 2,
			(self:GetCollisionProbeDistance() or 0) * 0.5,
			0.1
		)
		return (support.overhang_length or math.huge) <= tolerance, support
	end

	function RigidBody:RebuildColliders()
		local colliders = {}

		for index, entry in ipairs(Collider.BuildEntries(self)) do
			colliders[index] = Collider.New(self, entry, index):InvalidateGeometry()
		end

		self.Colliders = colliders
		self.CollisionLocalPoints = nil
		self.SupportLocalPoints = nil
		self.LocalBounds = nil
		return colliders
	end

	function RigidBody:GetColliders()
		if not self.Colliders or not self.Colliders[1] then
			self:RebuildColliders()
		end

		return self.Colliders
	end

	function RigidBody:GetPhysicsShape()
		local colliders = self:GetColliders()

		if #colliders ~= 1 then return nil end

		return colliders[1]:GetPhysicsShape()
	end

	function RigidBody:GetShapeType()
		local colliders = self:GetColliders()

		if #colliders ~= 1 then return "compound" end

		return colliders[1]:GetShapeType()
	end

	function RigidBody:OnAdd()
		local controller = self.Owner.kinematic_controller

		if controller and self:GetMotionType() ~= "kinematic" then
			self:SetMotionType("kinematic")
		end

		if self.Owner.transform then self:SynchronizeFromTransform() end
	end

	function RigidBody:OnRemove() end

	function RigidBody:OnGeometryChanged()
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

	function RigidBody:GetResolvedConvexHull()
		local colliders = self:GetColliders()

		if #colliders ~= 1 then return nil end

		return colliders[1]:GetResolvedConvexHull()
	end

	function RigidBody:RefreshMassProperties()
		local computed_mass = 0
		local inertia_tensor = new_zero_matrix()
		local has_collider_inertia = false

		for _, collider in ipairs(self:GetColliders()) do
			local collider_mass, collider_inertia_tensor = collider:GetPhysicsShape():GetMassProperties(collider)

			if collider_mass and collider_mass > 0 then
				computed_mass = computed_mass + collider_mass
				has_collider_inertia = true
				inertia_tensor:Add(
					rotate_inertia_tensor(collider:GetLocalRotation(), collider_inertia_tensor, Matrix33())
				)
				add_parallel_axis_term(inertia_tensor, collider_mass, collider:GetLocalPosition())
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
			self.InertiaTensor = new_zero_matrix()
			self.InverseInertiaTensor = new_zero_matrix()
			return
		end

		self.InverseMass = 1 / mass

		if has_collider_inertia and computed_mass > 0 then
			if not self:GetAutomaticMass() and mass ~= computed_mass then
				inertia_tensor = inertia_tensor:ScaleScalar(mass / computed_mass, Matrix33())
			else
				inertia_tensor = inertia_tensor:Copy()
			end

			self.InertiaTensor = inertia_tensor
			self.InverseInertiaTensor = get_inverse_tensor(inertia_tensor)
			return
		end

		local min_bounds, max_bounds = get_bounds_from_points(self:GetCollisionLocalPoints())

		if not (min_bounds and max_bounds) then
			self.InertiaTensor = new_zero_matrix()
			self.InverseInertiaTensor = new_zero_matrix()
			return
		end

		local size = max_bounds - min_bounds
		self.InertiaTensor = get_box_inertia_tensor(mass, size)
		self.InverseInertiaTensor = get_inverse_tensor(self.InertiaTensor)
		return
	end

	function RigidBody:GetBody()
		return self
	end

	function RigidBody:GetPhysics()
		return rawget(self, "Physics") or RigidBody.Physics
	end

	function RigidBody:GetKinematicController()
		return self.Owner and self.Owner.kinematic_controller or nil
	end

	function RigidBody:HasKinematicController()
		return self:GetKinematicController() ~= nil
	end

	function RigidBody:GetVelocity()
		return self.Velocity
	end

	function RigidBody:SetVelocity(vec)
		self.Velocity = vec:Copy()

		if
			self:HasSolverMass() and
			vec:GetLength() > math.max(self.SleepLinearThreshold or 0, 0)
		then
			self:Wake()
		end
	end

	function RigidBody:GetAngularVelocity()
		return self.AngularVelocity
	end

	function RigidBody:SetAngularVelocity(vec)
		self.AngularVelocity = vec:Copy()

		if
			self:HasSolverMass() and
			vec:GetLength() > math.max(self.SleepAngularThreshold or 0, 0)
		then
			self:Wake()
		end
	end

	function RigidBody:GetPosition()
		return self.Position
	end

	function RigidBody:SetPosition(vec)
		self.Position = vec:Copy()

		if self:HasSolverMass() then self:Wake() end
	end

	function RigidBody:GetPreviousPosition()
		return self.PreviousPosition
	end

	function RigidBody:GetRotation()
		return self.Rotation
	end

	function RigidBody:SetRotation(quat)
		self.Rotation = quat:Copy()

		if self:HasSolverMass() then self:Wake() end
	end

	function RigidBody:GetPreviousRotation()
		return self.PreviousRotation
	end

	function RigidBody:GetGroundNormal()
		return self.GroundNormal
	end

	function RigidBody:SetGroundNormal(vec)
		self.GroundNormal = vec:Copy()
	end

	function RigidBody:SetGrounded(grounded)
		self.Grounded = grounded

		if not grounded then
			self.GroundRollingFriction = 0
			self.GroundEntity = nil
			self.GroundBody = nil
		end
	end

	function RigidBody:GetGrounded()
		return self.Grounded
	end

	function RigidBody:GetAccumulatedForce()
		return self.AccumulatedForce
	end

	function RigidBody:GetAccumulatedTorque()
		return self.AccumulatedTorque
	end

	function RigidBody:ClearAccumulators()
		self.AccumulatedForce = Vec3()
		self.AccumulatedTorque = Vec3()
	end

	local angular_velocity_delta_impulse = Vec3()
	local angular_velocity_delta_local = Vec3()
	local angular_velocity_delta_conjugate = Quat()

	function RigidBody:GetAngularVelocityDelta(world_impulse)
		local rotation = self.Rotation
		local conjugate = angular_velocity_delta_conjugate
		conjugate.x, conjugate.y, conjugate.z, conjugate.w = -rotation.x, -rotation.y, -rotation.z, rotation.w
		Quat.SetVecMul(angular_velocity_delta_impulse, conjugate, world_impulse)
		self.InverseInertiaTensor:VecMul(angular_velocity_delta_impulse, angular_velocity_delta_impulse)
		return Quat.SetVecMul(angular_velocity_delta_local, rotation, angular_velocity_delta_impulse)
	end

	function RigidBody:ApplyAngularImpulse(world_impulse)
		if not self:HasSolverMass() then return self end

		if not self.Awake then self:Wake() end

		self.AngularVelocity = self.AngularVelocity + self:GetAngularVelocityDelta(world_impulse)
		return self
	end

	function RigidBody:ApplyImpulse(impulse, world_pos)
		if not self:HasSolverMass() then return self end

		if not self.Awake then self:Wake() end

		self.Velocity = self.Velocity + impulse * self.InverseMass

		if world_pos then
			self:ApplyAngularImpulse((world_pos - self.Position):GetCross(impulse))
		end

		return self
	end

	function RigidBody:ApplyTorque(torque)
		if not self:HasSolverMass() then return self end

		if not self.Awake then self:Wake() end

		self.AccumulatedTorque = self.AccumulatedTorque + torque
		return self
	end

	function RigidBody:ApplyForce(force, world_pos)
		if not self:HasSolverMass() then return self end

		if not self.Awake then self:Wake() end

		self.AccumulatedForce = self.AccumulatedForce + force

		if world_pos then
			self:ApplyTorque((world_pos - self.Position):GetCross(force))
		end

		return self
	end

	RigidBody.AddForce = RigidBody.ApplyForce
	RigidBody.AddTorque = RigidBody.ApplyTorque
	RigidBody.AddImpulse = RigidBody.ApplyImpulse

	function RigidBody:Wake()
		if not self:HasSolverMass() then return end

		-- only a genuine asleep-to-awake transition resets the sleep timer; an
		-- already awake body keeps accumulating its delay, otherwise resting
		-- micro-corrections that wake a body every substep would starve it of
		-- sleep forever. Real motion resets the timer through the speed check
		-- in UpdateSleepState
		if not self.Awake then
			self.Awake = true
			self.SleepTimer = 0
			stats:Count("woken_bodies")
		end
	end

	function RigidBody:Sleep()
		if not self:HasSolverMass() then return end

		if self.Awake then stats:Count("slept_bodies") end

		self.Awake = false
		self.SleepTimer = 0
		self.Velocity = Vec3(0, 0, 0)
		self.AngularVelocity = Vec3(0, 0, 0)
		self.PreviousPosition = self.Position:Copy()
		self.PreviousRotation = self.Rotation:Copy()
	end

	local function get_sleep_state_metrics(self)
		local linear_threshold = self.SleepLinearThreshold
		local angular_threshold = self.SleepAngularThreshold
		local linear_speed = self.Velocity:GetLength()
		local angular_speed = self.AngularVelocity:GetLength()
		local force_grounded_sleep = false

		if self:GetGrounded() then
			linear_threshold = linear_threshold * 1.2
			angular_threshold = angular_threshold * 1.4
			local shape = self:GetPhysicsShape()
			local ground_body = self.GroundBody
			local ground_ready_to_sleep = ground_body and ground_body:IsReadyToSleep() or false
			local allow_grounded_sleep_assist = not (
				ground_body and
				ground_body ~= self and
				ground_body:HasSolverMass() and
				ground_body:GetAwake() and
				not ground_ready_to_sleep
			)
			force_grounded_sleep = allow_grounded_sleep_assist and
				shape and
				shape.ShouldForceGroundedSleep and
				shape:ShouldForceGroundedSleep(self) and
				linear_speed <= math.max(0.02, self.SleepLinearThreshold * 0.35)
				and
				angular_speed <= math.max(0.03, self.SleepAngularThreshold * 0.35)
		end

		return linear_speed,
		angular_speed,
		linear_threshold,
		angular_threshold,
		force_grounded_sleep
	end

	local function get_effective_sleep_delay(self)
		return math.max(self.SleepDelay or 0, 0)
	end

	function RigidBody:IsReadyToSleep()
		if not self:HasSolverMass() or not self.CanSleep then return false, false end

		if not self.Awake then return true, false end

		if self._evaluating_ready_to_sleep then return false, false end

		self._evaluating_ready_to_sleep = true
		local linear_speed, angular_speed, linear_threshold, angular_threshold, force_grounded_sleep = get_sleep_state_metrics(self)
		self._evaluating_ready_to_sleep = nil

		if force_grounded_sleep then return true, true end

		return linear_speed <= linear_threshold and angular_speed <= angular_threshold,
		false
	end

	function RigidBody:CanSleepNow()
		if not self:HasSolverMass() or not self.CanSleep then return false, false end

		if not self.Awake then return true, false end

		local ready_to_sleep, force_grounded_sleep = self:IsReadyToSleep()

		if not ready_to_sleep then return false, force_grounded_sleep end

		return self.SleepTimer >= get_effective_sleep_delay(self, force_grounded_sleep),
		force_grounded_sleep
	end

	function RigidBody:UpdateSleepState(dt)
		if not self:HasSolverMass() or not self.CanSleep then return end

		if not self.Awake then
			self.Velocity = Vec3(0, 0, 0)
			self.AngularVelocity = Vec3(0, 0, 0)
			self.PreviousPosition = self.Position:Copy()
			self.PreviousRotation = self.Rotation:Copy()
			return
		end

		local ready_to_sleep, force_grounded_sleep = self:IsReadyToSleep()

		if force_grounded_sleep then
			self:Sleep()
			return
		end

		if ready_to_sleep then
			self.SleepTimer = self.SleepTimer + dt

			if self.SleepTimer >= get_effective_sleep_delay(self) then
				self:Sleep()
			end
		else
			self.SleepTimer = 0
		end
	end

	function RigidBody:GetHalfExtents()
		local bounds = self.LocalBounds

		if not bounds then
			local min_bounds, max_bounds = get_bounds_from_points(self:GetCollisionLocalPoints())

			if not (min_bounds and max_bounds) then return Vec3(0.5, 0.5, 0.5) end

			bounds = {min = min_bounds, max = max_bounds}
			self.LocalBounds = bounds
		end

		return (bounds.max - bounds.min) * 0.5
	end

	function RigidBody:IsStatic()
		return self.MotionType == "static"
	end

	function RigidBody:IsKinematic()
		return self.MotionType == "kinematic"
	end

	function RigidBody:IsDynamic()
		return self.MotionType == "dynamic"
	end

	function RigidBody:HasSolverMass()
		return self:IsDynamic() and (self.InverseMass or 0) > 0
	end

	function RigidBody:IsSolverImmovable()
		return not self:HasSolverMass()
	end

	function RigidBody:ShouldCollide(body)
		if self == body then return false end

		local group_a = self.CollisionGroup or 1
		local group_b = body.CollisionGroup or 1
		local mask_a = self.CollisionMask
		local mask_b = body.CollisionMask
		mask_a = mask_a == nil and -1 or mask_a
		mask_b = mask_b == nil and -1 or mask_b
		return bit.band(mask_a, group_b) ~= 0 and bit.band(mask_b, group_a) ~= 0
	end

	function RigidBody:SynchronizeFromTransform()
		if not (self.Owner and self.Owner.transform) then return end

		local position = self.Owner.transform:GetPosition():Copy()
		local rotation = self.Owner.transform:GetRotation():Copy()

		if self:IsKinematic() then
			self.PreviousPosition = self.Position:Copy()
			self.PreviousRotation = self.Rotation:Copy()
		else
			self.PreviousPosition = position:Copy()
			self.PreviousRotation = rotation:Copy()
		end

		self.Position = position
		self.Rotation = rotation
	end

	function RigidBody:WriteToTransform()
		if not (self.Owner and self.Owner.transform) then return end

		self.Owner.transform:SetPosition(self.Position:Copy())
		self.Owner.transform:SetRotation(self.Rotation:Copy())
	end

	function RigidBody:ShouldInterpolateTransform()
		return self:IsDynamic() and
			self.PreviousPosition and
			self.PreviousRotation and
			self.Position and
			self.Rotation
	end

	function RigidBody:GetInterpolatedPosition(alpha)
		if not self:ShouldInterpolateTransform() then return self.Position end

		return self.PreviousPosition:GetLerped(math.clamp(alpha or 0, 0, 1), self.Position)
	end

	function RigidBody:GetInterpolatedRotation(alpha)
		if not self:ShouldInterpolateTransform() then return self.Rotation end

		return self.PreviousRotation:Interpolate(self.Rotation, math.clamp(alpha or 0, 0, 1))
	end

	function RigidBody:LocalToWorld(local_pos, position, rotation, out)
		position = position or self.Position
		rotation = rotation or self.Rotation
		out = Quat.SetVecMul(out or Vec3(), rotation, local_pos)
		out.x = out.x + position.x
		out.y = out.y + position.y
		out.z = out.z + position.z
		return out
	end

	function RigidBody:GeometryLocalToWorld(local_pos, position, rotation, out)
		return self:LocalToWorld(local_pos, position, rotation, out)
	end

	function RigidBody:WorldToLocal(world_pos, position, rotation, out)
		position = position or self.Position
		rotation = rotation or self.Rotation
		local dx = world_pos.x - position.x
		local dy = world_pos.y - position.y
		local dz = world_pos.z - position.z
		local qx = -rotation.x
		local qy = -rotation.y
		local qz = -rotation.z
		local qw = rotation.w
		local tx = 2 * (qy * dz - qz * dy)
		local ty = 2 * (qz * dx - qx * dz)
		local tz = 2 * (qx * dy - qy * dx)
		out = out or Vec3()
		out.x = dx + qw * tx + (qy * tz - qz * ty)
		out.y = dy + qw * ty + (qz * tx - qx * tz)
		out.z = dz + qw * tz + (qx * ty - qy * tx)
		return out
	end

	local rigid_body_aabb_position = Vec3(0, 0, 0)

	function RigidBody:GetBroadphaseAABB(position, rotation, out)
		position = position or self.Position
		rotation = rotation or self.Rotation
		local colliders = self:GetColliders()

		if #colliders == 1 then
			local collider = colliders[1]
			local local_position = collider:GetLocalPosition()
			local local_rotation = collider:GetLocalRotation()

			-- collider at the body origin with identity local rotation:
			-- the shape aabb is the body aabb, no intermediate allocations
			if
				local_position.x == 0 and
				local_position.y == 0 and
				local_position.z == 0 and
				local_rotation.x == 0 and
				local_rotation.y == 0 and
				local_rotation.z == 0
			then
				return collider:GetBroadphaseAABB(position, rotation, out)
			end

			local collider_position = rotation:VecMul(local_position, rigid_body_aabb_position)
			collider_position.x = collider_position.x + position.x
			collider_position.y = collider_position.y + position.y
			collider_position.z = collider_position.z + position.z
			local collider_rotation = (rotation * local_rotation):GetNormalized()
			return collider:GetBroadphaseAABB(collider_position, collider_rotation, out)
		end

		local min_x = math.huge
		local min_y = math.huge
		local min_z = math.huge
		local max_x = -math.huge
		local max_y = -math.huge
		local max_z = -math.huge
		local has_bounds = false

		for i = 1, #colliders do
			local collider = colliders[i]
			local collider_position = position + rotation:VecMul(collider:GetLocalPosition())
			local collider_rotation = (rotation * collider:GetLocalRotation()):GetNormalized()
			local bounds = collider:GetBroadphaseAABB(collider_position, collider_rotation)

			if bounds.min_x < min_x then min_x = bounds.min_x end

			if bounds.min_y < min_y then min_y = bounds.min_y end

			if bounds.min_z < min_z then min_z = bounds.min_z end

			if bounds.max_x > max_x then max_x = bounds.max_x end

			if bounds.max_y > max_y then max_y = bounds.max_y end

			if bounds.max_z > max_z then max_z = bounds.max_z end

			has_bounds = true
		end

		if not has_bounds then
			local half = Vec3(0.5, 0.5, 0.5)

			if out then
				out.min_x = position.x - half.x
				out.min_y = position.y - half.y
				out.min_z = position.z - half.z
				out.max_x = position.x + half.x
				out.max_y = position.y + half.y
				out.max_z = position.z + half.z
				return out
			end

			return AABB(
				position.x - half.x,
				position.y - half.y,
				position.z - half.z,
				position.x + half.x,
				position.y + half.y,
				position.z + half.z
			)
		end

		if out then
			out.min_x = min_x
			out.min_y = min_y
			out.min_z = min_z
			out.max_x = max_x
			out.max_y = max_y
			out.max_z = max_z
			return out
		end

		return AABB(min_x, min_y, min_z, max_x, max_y, max_z)
	end

	function RigidBody:Integrate(dt, gravity)
		self.StepDt = dt
		self.PreviousPosition = self.Position:Copy()
		self.PreviousRotation = self.Rotation:Copy()

		if self:IsKinematic() then return end

		if not self:HasSolverMass() or not self.Awake then return end

		self.Velocity:AddScaled(gravity, self.GravityScale * dt)
		self.Velocity:AddScaled(self.AccumulatedForce, self.InverseMass * dt)
		TEMPORARY_TORQUE:CopyFrom(self.AccumulatedTorque):Scale(dt)
		self.AngularVelocity:Add(self:GetAngularVelocityDelta(TEMPORARY_TORQUE))
		self.Velocity = clamp_vec_length(self.Velocity, self.MaxLinearSpeed)
		self.AngularVelocity = clamp_vec_length(self.AngularVelocity, self.MaxAngularSpeed)
		self.Position:AddScaled(self.Velocity, dt)
		self.Rotation = integrate_rotation(self.Rotation, self.AngularVelocity, dt)
	end

	local UPDATE_DELTA = Quat()
	local UPDATE_CONJUGATE = Quat()

	function RigidBody:UpdateVelocities(dt)
		if self:IsKinematic() then
			self.Velocity:CopyFrom(self.Position):Sub(self.PreviousPosition):Scale(1 / dt)
			Quat.SetConjugated(UPDATE_CONJUGATE, self.PreviousRotation)
			Quat.SetMul(UPDATE_DELTA, self.Rotation, UPDATE_CONJUGATE)
			UPDATE_DELTA:Normalize()
			self.AngularVelocity:Set(UPDATE_DELTA.x * 2 / dt, UPDATE_DELTA.y * 2 / dt, UPDATE_DELTA.z * 2 / dt)

			if UPDATE_DELTA.w < 0 then self.AngularVelocity:Scale(-1) end

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

		if self.Grounded then
			local use_grounded_velocity_constraints = self:IsGroundSupportStable()
			local shape = self:GetPhysicsShape()

			if shape and shape.ShouldUseGroundedVelocityConstraints then
				use_grounded_velocity_constraints = shape:ShouldUseGroundedVelocityConstraints(self, use_grounded_velocity_constraints) == true
			end

			local normal_speed = self.Velocity:Dot(self.GroundNormal)

			if use_grounded_velocity_constraints and normal_speed < 0 then
				self.Velocity:AddScaled(self.GroundNormal, -normal_speed)
			end

			if use_grounded_velocity_constraints then
				for _, collider in ipairs(self:GetColliders()) do
					collider:GetPhysicsShape():OnGroundedVelocityUpdate(self, dt)
				end
			end

			self._use_grounded_velocity_constraints = use_grounded_velocity_constraints
		else
			self._use_grounded_velocity_constraints = false
		end

		local grounded_damping = self.Grounded and self._use_grounded_velocity_constraints
		local linear_damping_value = grounded_damping and self.LinearDamping or self.AirLinearDamping
		local angular_damping_value = grounded_damping and self.AngularDamping or self.AirAngularDamping
		local linear_damping = math.max(1 - linear_damping_value * dt, 0)
		local angular_damping = math.max(1 - angular_damping_value * dt, 0)
		self.Velocity:Scale(linear_damping)
		self.AngularVelocity:Scale(angular_damping)
		self.Velocity = clamp_vec_length(self.Velocity, self.MaxLinearSpeed)
		self.AngularVelocity = clamp_vec_length(self.AngularVelocity, self.MaxAngularSpeed)
	end

	local inv_mass_tangent = Vec3()
	local inv_mass_local = Vec3()
	local inv_mass_delta = Vec3()
	local inv_mass_conjugate = Quat()
	local CORRECTION_ANGULAR = Vec3()
	local CORRECTION_ANGULAR_2 = Vec3()
	local CORRECTION_IMPULSE = Vec3()
	local CORRECTION_POS_DELTA = Vec3()
	local CORRECTION_CONJUGATE = Quat()
	local CORRECTION_DELTA = Quat()
	local CORRECTION_NORMAL = Vec3()
	local CORRECTION_IMPULSE_A = Vec3()
	local CORRECTION_IMPULSE_B = Vec3()
	local CORRECTION_PREV_POS = Vec3()
	local CORRECTION_PREV_ROT = Quat()
	local CORRECTION_DIFF = Vec3()
	local CORRECTION_DELTA_ROT = Quat()

	function RigidBody:GetInverseMassAlong(normal, pos)
		if not self:HasSolverMass() then return 0 end

		local tangent = inv_mass_tangent

		if pos then
			local p = self.Position
			tangent.x, tangent.y, tangent.z = pos.x - p.x, pos.y - p.y, pos.z - p.z
			Vec3.Cross(tangent, normal)
		else
			tangent.x, tangent.y, tangent.z = normal.x, normal.y, normal.z
		end

		local r = self.Rotation
		local conjugate = inv_mass_conjugate
		conjugate.x, conjugate.y, conjugate.z, conjugate.w = -r.x, -r.y, -r.z, r.w
		Quat.SetVecMul(inv_mass_local, conjugate, tangent)
		self.InverseInertiaTensor:VecMul(inv_mass_local, inv_mass_delta)
		local angular = inv_mass_local.x * inv_mass_delta.x + inv_mass_local.y * inv_mass_delta.y + inv_mass_local.z * inv_mass_delta.z

		if pos then angular = angular + self.InverseMass end

		return angular
	end

	function RigidBody:_ApplyCorrection(correction, pos)
		if not self:HasSolverMass() then return end

		self.Position:AddScaled(correction, self.InverseMass)

		if not pos then return end

		Vec3.SetSub(CORRECTION_ANGULAR, pos, self.Position)
		Vec3.SetCross(CORRECTION_ANGULAR, CORRECTION_ANGULAR, correction)
		Quat.SetConjugated(CORRECTION_CONJUGATE, self.Rotation)
		Quat.SetVecMul(CORRECTION_ANGULAR_2, CORRECTION_CONJUGATE, CORRECTION_ANGULAR)
		self.InverseInertiaTensor:VecMul(CORRECTION_ANGULAR_2, CORRECTION_ANGULAR_2)
		Quat.SetVecMul(CORRECTION_ANGULAR_2, self.Rotation, CORRECTION_ANGULAR_2)
		local delta = CORRECTION_DELTA
		delta.x, delta.y, delta.z, delta.w = CORRECTION_ANGULAR_2.x, CORRECTION_ANGULAR_2.y, CORRECTION_ANGULAR_2.z, 0
		Quat.SetMul(delta, delta, self.Rotation)
		self.Rotation.x = self.Rotation.x + 0.5 * delta.x
		self.Rotation.y = self.Rotation.y + 0.5 * delta.y
		self.Rotation.z = self.Rotation.z + 0.5 * delta.z
		self.Rotation.w = self.Rotation.w + 0.5 * delta.w
		self.Rotation:Normalize()
	end

	function RigidBody:ApplyCorrection(compliance, correction, pos, other_body, other_pos, dt)
		local length = correction:GetLength()

		if length == 0 then return 0 end

		dt = dt or self.StepDt

		if not dt or dt <= 0 then dt = 1 / 60 end

		local normal = CORRECTION_NORMAL
		normal.x = correction.x / length
		normal.y = correction.y / length
		normal.z = correction.z / length
		local inverse_mass = self:GetInverseMassAlong(normal, pos)

		if other_body then
			inverse_mass = inverse_mass + other_body:GetInverseMassAlong(normal, other_pos)
		end

		if inverse_mass == 0 then return 0 end

		local alpha = (compliance or 0) / (dt * dt)
		local lambda = -length / (inverse_mass + alpha)
		local impulse = CORRECTION_IMPULSE_A
		local impulse_scale = -lambda
		impulse.x = normal.x * impulse_scale
		impulse.y = normal.y * impulse_scale
		impulse.z = normal.z * impulse_scale
		local prev_pos = CORRECTION_PREV_POS
		local prev_rot = CORRECTION_PREV_ROT
		prev_pos.x, prev_pos.y, prev_pos.z = self.Position.x, self.Position.y, self.Position.z
		prev_rot.x, prev_rot.y, prev_rot.z, prev_rot.w = self.Rotation.x, self.Rotation.y, self.Rotation.z, self.Rotation.w
		self:_ApplyCorrection(impulse, pos)
		Vec3.SetSub(CORRECTION_DIFF, self.Position, prev_pos)
		local dx = CORRECTION_DIFF.x
		local dy = CORRECTION_DIFF.y
		local dz = CORRECTION_DIFF.z

		if not self.Awake and CORRECTION_DIFF:GetLength() > 0.001 then
			self:Wake()
		end

		self.PreviousPosition.x = self.PreviousPosition.x + dx
		self.PreviousPosition.y = self.PreviousPosition.y + dy
		self.PreviousPosition.z = self.PreviousPosition.z + dz
		Quat.SetConjugated(CORRECTION_DELTA_ROT, prev_rot)
		Quat.SetMul(CORRECTION_DELTA_ROT, self.Rotation, CORRECTION_DELTA_ROT)
		Quat.SetMul(prev_rot, CORRECTION_DELTA_ROT, self.PreviousRotation)
		prev_rot:Normalize()
		self.PreviousRotation.x = prev_rot.x
		self.PreviousRotation.y = prev_rot.y
		self.PreviousRotation.z = prev_rot.z
		self.PreviousRotation.w = prev_rot.w

		if other_body then
			local impulse_b = CORRECTION_IMPULSE_B
			impulse_b.x = -impulse.x
			impulse_b.y = -impulse.y
			impulse_b.z = -impulse.z
			prev_pos.x, prev_pos.y, prev_pos.z = other_body.Position.x, other_body.Position.y, other_body.Position.z
			prev_rot.x, prev_rot.y, prev_rot.z, prev_rot.w = other_body.Rotation.x, other_body.Rotation.y, other_body.Rotation.z, other_body.Rotation.w
			other_body:_ApplyCorrection(impulse_b, other_pos)
			Vec3.SetSub(CORRECTION_DIFF, other_body.Position, prev_pos)
			dx = CORRECTION_DIFF.x
			dy = CORRECTION_DIFF.y
			dz = CORRECTION_DIFF.z

			if not other_body.Awake and CORRECTION_DIFF:GetLength() > 0.001 then
				other_body:Wake()
			end

			other_body.PreviousPosition.x = other_body.PreviousPosition.x + dx
			other_body.PreviousPosition.y = other_body.PreviousPosition.y + dy
			other_body.PreviousPosition.z = other_body.PreviousPosition.z + dz
			Quat.SetConjugated(CORRECTION_DELTA_ROT, prev_rot)
			Quat.SetMul(CORRECTION_DELTA_ROT, other_body.Rotation, CORRECTION_DELTA_ROT)
			Quat.SetMul(prev_rot, CORRECTION_DELTA_ROT, other_body.PreviousRotation)
			prev_rot:Normalize()
			other_body.PreviousRotation.x = prev_rot.x
			other_body.PreviousRotation.y = prev_rot.y
			other_body.PreviousRotation.z = prev_rot.z
			other_body.PreviousRotation.w = prev_rot.w
		end

		return lambda / (dt * dt)
	end

	function RigidBody:BuildCollisionLocalPoints()
		local points = {}

		for _, collider in ipairs(self:GetColliders()) do
			for _, point in ipairs(collider:GetCollisionLocalPoints() or {}) do
				points[#points + 1] = collider:GetLocalPosition() + collider:GetLocalRotation():VecMul(point)
			end
		end

		return points
	end

	function RigidBody:GetCollisionLocalPoints()
		if not self.CollisionLocalPoints then
			self.CollisionLocalPoints = self:BuildCollisionLocalPoints()
		end

		return self.CollisionLocalPoints
	end

	function RigidBody:BuildSupportLocalPoints()
		local points = {}

		for _, collider in ipairs(self:GetColliders()) do
			for _, point in ipairs(collider:GetSupportLocalPoints() or {}) do
				points[#points + 1] = collider:GetLocalPosition() + collider:GetLocalRotation():VecMul(point)
			end
		end

		return points
	end

	function RigidBody:GetSupportLocalPoints()
		if not self.SupportLocalPoints then
			self.SupportLocalPoints = self:BuildSupportLocalPoints()
		end

		return self.SupportLocalPoints
	end

	function RigidBody:GetSphereRadius()
		local shape = self:GetPhysicsShape()
		return shape and shape.GetRadius and shape:GetRadius() or 0
	end

	function RigidBody:GetBodyPolyhedron()
		local shape = self:GetPhysicsShape()

		if not (shape and shape.GetPolyhedron) then return nil end

		return shape:GetPolyhedron(self)
	end

	function RigidBody:BodyHasSignificantRotation()
		return math.abs(self:GetPreviousRotation():Dot(self:GetRotation())) < 0.9995
	end

	RigidBody:Register()
	Entity.RegisterComponent("rigid_body", RigidBody)
end

return RigidBody
