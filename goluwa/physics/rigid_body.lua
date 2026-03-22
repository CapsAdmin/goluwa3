local prototype = import("goluwa/prototype.lua")
local bit = require("bit")
local physics_constants = import("goluwa/physics/constants.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Matrix33 = import("goluwa/structs/matrix33.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Collider = import("goluwa/physics/collider.lua")
local Entity = import("goluwa/ecs/entity.lua")
local RigidBody = prototype.CreateTemplate("rigid_body")

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

	function RigidBody:OnAdd(entity)
		self.Owner = entity
		local controller = entity.kinematic_controller

		if controller and self:GetMotionType() ~= "kinematic" then
			self:SetMotionType("kinematic")
		end

		if entity.transform then self:SynchronizeFromTransform() end
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

	function RigidBody:GetAngularVelocityDelta(world_impulse)
		local local_impulse = self.Rotation:GetConjugated():VecMul(world_impulse)
		local local_delta = self.InverseInertiaTensor:VecMul(local_impulse)
		return self.Rotation:VecMul(local_delta)
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

		self.Awake = true
		self.SleepTimer = 0
	end

	function RigidBody:Sleep()
		if not self:HasSolverMass() then return end

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
			local shape = self.GetPhysicsShape and self:GetPhysicsShape() or nil
			local ground_body = self.GetGroundBody and self:GetGroundBody() or nil
			local ground_ready_to_sleep = ground_body and
				ground_body.IsReadyToSleep and
				ground_body:IsReadyToSleep() or
				false
			local allow_grounded_sleep_assist = not (
				ground_body and
				ground_body ~= self and
				ground_body.HasSolverMass and
				ground_body:HasSolverMass() and
				ground_body.GetAwake and
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

		if ready_to_sleep then
			self.SleepTimer = self.SleepTimer + dt

			if self.SleepTimer >= get_effective_sleep_delay(self, force_grounded_sleep) then
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

		local group_a = self.GetCollisionGroup and
			self:GetCollisionGroup() or
			self.CollisionGroup or
			1
		local group_b = body.GetCollisionGroup and
			body:GetCollisionGroup() or
			body.CollisionGroup or
			1
		local mask_a = self.GetCollisionMask and self:GetCollisionMask() or self.CollisionMask
		local mask_b = body.GetCollisionMask and body:GetCollisionMask() or body.CollisionMask
		mask_a = mask_a == nil and -1 or mask_a
		mask_b = mask_b == nil and -1 or mask_b
		return bit.band(mask_a, group_b) ~= 0 and bit.band(mask_b, group_a) ~= 0
	end

	function RigidBody:SynchronizeFromTransform()
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

		alpha = math.min(math.max(alpha or 0, 0), 1)
		return self.PreviousPosition + (self.Position - self.PreviousPosition) * alpha
	end

	function RigidBody:GetInterpolatedRotation(alpha)
		if not self:ShouldInterpolateTransform() then return self.Rotation end

		alpha = math.min(math.max(alpha or 0, 0), 1)
		local previous = self.PreviousRotation
		local current = self.Rotation

		if previous:Dot(current) < 0 then current = current * -1 end

		return previous:GetLerped(alpha, current):GetNormalized()
	end

	function RigidBody:LocalToWorld(local_pos, position, rotation)
		position = position or self.Position
		rotation = rotation or self.Rotation
		return position + rotation:VecMul(local_pos)
	end

	function RigidBody:GeometryLocalToWorld(local_pos, position, rotation)
		return self:LocalToWorld(local_pos, position, rotation)
	end

	function RigidBody:WorldToLocal(world_pos, position, rotation)
		position = position or self.Position
		rotation = rotation or self.Rotation
		return rotation:GetConjugated():VecMul(world_pos - position)
	end

	function RigidBody:GetBroadphaseAABB(position, rotation)
		position = position or self.Position
		rotation = rotation or self.Rotation
		local min_x = math.huge
		local min_y = math.huge
		local min_z = math.huge
		local max_x = -math.huge
		local max_y = -math.huge
		local max_z = -math.huge
		local has_bounds = false
		local colliders = self:GetColliders()

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
			return AABB(
				position.x - half.x,
				position.y - half.y,
				position.z - half.z,
				position.x + half.x,
				position.y + half.y,
				position.z + half.z
			)
		end

		return AABB(min_x, min_y, min_z, max_x, max_y, max_z)
	end

	function RigidBody:Integrate(dt, gravity)
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

	function RigidBody:UpdateVelocities(dt)
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

		if self.Grounded then
			local use_grounded_velocity_constraints = self:IsGroundSupportStable()
			local normal_speed = self.Velocity:Dot(self.GroundNormal)

			if use_grounded_velocity_constraints and normal_speed < 0 then
				self.Velocity = self.Velocity - self.GroundNormal * normal_speed
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
		self.Velocity = clamp_vec_length(self.Velocity * linear_damping, self.MaxLinearSpeed)
		self.AngularVelocity = clamp_vec_length(self.AngularVelocity * angular_damping, self.MaxAngularSpeed)
	end

	function RigidBody:GetInverseMassAlong(normal, pos)
		if not self:HasSolverMass() then return 0 end

		local tangent = normal:Copy()

		if pos then tangent = (pos - self.Position):GetCross(normal) end

		tangent = self.Rotation:GetConjugated():VecMul(tangent)
		local angular_delta = self.InverseInertiaTensor:VecMul(tangent)
		local angular = tangent:Dot(angular_delta)

		if pos then angular = angular + self.InverseMass end

		return angular
	end

	function RigidBody:_ApplyCorrection(correction, pos)
		if not self:HasSolverMass() then return end

		self.Position = self.Position + correction * self.InverseMass

		if not pos then return end

		local angular = (pos - self.Position):GetCross(correction)
		angular = self.Rotation:GetConjugated():VecMul(angular)
		angular = self.InverseInertiaTensor:VecMul(angular)
		angular = self.Rotation:VecMul(angular)
		local delta = Quat(angular.x, angular.y, angular.z, 0) * self.Rotation
		self.Rotation = Quat(
			self.Rotation.x + 0.5 * delta.x,
			self.Rotation.y + 0.5 * delta.y,
			self.Rotation.z + 0.5 * delta.z,
			self.Rotation.w + 0.5 * delta.w
		):GetNormalized()
	end

	function RigidBody:ApplyCorrection(compliance, correction, pos, other_body, other_pos, dt)
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
		local self_previous_position = self.Position:Copy()
		local self_previous_rotation = self.Rotation:Copy()
		self:_ApplyCorrection(impulse, pos)
		self.PreviousPosition = self.PreviousPosition + (self.Position - self_previous_position)
		self.PreviousRotation = (
			(
				self.Rotation * self_previous_rotation:GetConjugated()
			) * self.PreviousRotation
		):GetNormalized()

		if other_body then
			local other_previous_position = other_body.Position:Copy()
			local other_previous_rotation = other_body.Rotation:Copy()
			other_body:_ApplyCorrection(impulse * -1, other_pos)
			other_body.PreviousPosition = other_body.PreviousPosition + (other_body.Position - other_previous_position)
			other_body.PreviousRotation = (
				(
					other_body.Rotation * other_previous_rotation:GetConjugated()
				) * other_body.PreviousRotation
			):GetNormalized()
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
