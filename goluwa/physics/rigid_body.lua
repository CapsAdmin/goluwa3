local objects = import("goluwa/objects/objects.lua")
local bit = require("bit")
local physics_constants = import("goluwa/physics/constants.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Matrix33 = import("goluwa/structs/matrix33.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Collider = import("goluwa/physics/collider.lua")
local islands = import("goluwa/physics/islands.lua")
local Entity = import("goluwa/entities/entity.lua")
local stats = import("goluwa/physics/stats.lua")
local motion = import("goluwa/physics/motion.lua")
local RigidBody = objects.CreateTemplate("rigid_body")
local COMBINE_MODES = {"average", "min", "multiply", "max"}
RigidBody:GetSet("Shape", nil, {callback = "OnGeometryChanged"})
RigidBody:GetSet("Shapes", nil, {callback = "OnGeometryChanged"})
RigidBody:StartStorable()
RigidBody:GetSet(
	"MotionType",
	"dynamic",
	{callback = "OnMotionTypeChanged", enums = {"dynamic", "kinematic", "static"}}
)
RigidBody:GetSet("Density", 1, {callback = "RefreshMassProperties"})
RigidBody:GetSet("Mass", 1, {callback = "RefreshMassProperties"})
RigidBody:GetSet("AutomaticMass", true, {callback = "RefreshMassProperties"})
RigidBody:GetSet("Inertia", nil, {callback = "RefreshMassProperties"})
RigidBody:GetSet("LockRotation", false, {callback = "RefreshMassProperties"})
RigidBody:GetSet("GravityScale", 1)
RigidBody:GetSet("LinearDamping", 0)
RigidBody:GetSet("AngularDamping", 0)
RigidBody:GetSet("AirLinearDamping", 0)
RigidBody:GetSet("AirAngularDamping", 0)
RigidBody:GetSet("CollisionEnabled", true, {callback = "OnCollisionEnabledChanged"})
RigidBody:GetSet("WorldGeometry", false, {callback = "OnWorldGeometryChanged"})
RigidBody:GetSet("CollisionGroup", 1, {validate = "integer"})
RigidBody:GetSet("CollisionMask", -1, {validate = "integer"})
RigidBody:GetSet("CCD", false)
RigidBody:GetSet("AutoCCD", true)
RigidBody:GetSet("AutoCCDThreshold", 0.5)
RigidBody:GetSet("CollisionMargin", physics_constants.DEFAULT_COLLISION_MARGIN)
RigidBody:GetSet("CollisionProbeDistance", nil, {type = "number"})
RigidBody:GetSet("Friction", 0)
RigidBody:GetSet("StaticFriction", nil, {type = "number"})
RigidBody:GetSet("RollingFriction", 0)
RigidBody:GetSet("Restitution", 0)
RigidBody:GetSet("FrictionCombineMode", nil, {enums = COMBINE_MODES})
RigidBody:GetSet("StaticFrictionCombineMode", nil, {enums = COMBINE_MODES})
RigidBody:GetSet("RollingFrictionCombineMode", nil, {enums = COMBINE_MODES})
RigidBody:GetSet("RestitutionCombineMode", nil, {enums = COMBINE_MODES})
RigidBody:GetSet("CanSleep", true)
RigidBody:GetSet("SleepLinearThreshold", 0.06)
RigidBody:GetSet("SleepAngularThreshold", 0.06)
RigidBody:GetSet("SleepDelay", 0.5)
RigidBody:GetSet("MaxLinearSpeed", 240)
RigidBody:GetSet("MaxAngularSpeed", 60)
RigidBody:GetSet("MinGroundNormalY", 0.2)
RigidBody:EndStorable()
RigidBody:GetSet("Awake", true, {callback = "OnActivityChanged"})
RigidBody:GetSet("FilterFunction", nil)
RigidBody:GetSet("Grounded", false)
RigidBody:GetSet("GroundRollingFriction", 0)
RigidBody:GetSet("GroundEntity", nil)
RigidBody:GetSet("GroundBody", nil)
RigidBody.ActivityEpoch = 0
RigidBody.TransformDirtyBodies = {}
RigidBody.RemovedBodies = {}

function RigidBody:OnActivityChanged()
	RigidBody.ActivityEpoch = RigidBody.ActivityEpoch + 1
end

function RigidBody:OnCollisionEnabledChanged()
	self:MarkTransformDirty()
end

function RigidBody:MarkTransformDirty()
	if self.TransformDirty then return end

	self.TransformDirty = true
	local dirty = RigidBody.TransformDirtyBodies
	dirty[#dirty + 1] = self
end

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

local function build_ground_support_basis(normal, tangent, bitangent)
	local nx, ny, nz = normal.x, normal.y, normal.z
	local tx, ty, tz

	if math.abs(nx) < 0.8 then
		tx, ty, tz = 0, nz, -ny
	else
		tx, ty, tz = -nz, 0, nx
	end

	local length = math.sqrt(tx * tx + ty * ty + tz * tz)

	if length <= physics_constants.EPSILON then
		tx, ty, tz = ny, -nx, 0
		length = math.sqrt(tx * tx + ty * ty + tz * tz)

		if length <= physics_constants.EPSILON then return false end
	end

	tx, ty, tz = tx / length, ty / length, tz / length
	tangent.x, tangent.y, tangent.z = tx, ty, tz
	local bx = ny * tz - nz * ty
	local by = nz * tx - nx * tz
	local bz = nx * ty - ny * tx
	length = math.sqrt(bx * bx + by * by + bz * bz)
	bitangent.x, bitangent.y, bitangent.z = bx / length, by / length, bz / length
	return true
end

function RigidBody:Initialize()
	self.Velocity = self.Velocity or Vec3(0, 0, 0)
	self.AngularVelocity = self.AngularVelocity or Vec3(0, 0, 0)
	self.Position = self.Position or Vec3(0, 0, 0)
	self.PreviousPosition = self.PreviousPosition or Vec3(0, 0, 0)
	self.Rotation = self.Rotation or Quat(0, 0, 0, 1)
	self.PreviousRotation = self.PreviousRotation or Quat(0, 0, 0, 1)
	self.StepStartPosition = self.StepStartPosition or Vec3(0, 0, 0)
	self.StepStartRotation = self.StepStartRotation or Quat(0, 0, 0, 1)
	self.GroundNormal = self.GroundNormal or Vec3(0, 1, 0)
	self.InverseMass = self.InverseMass or 0
	self.InertiaTensor = self.InertiaTensor or new_zero_matrix()
	self.InverseInertiaTensor = self.InverseInertiaTensor or new_zero_matrix()
	self.StepDt = self.StepDt or 0
	self.SleepTimer = self.SleepTimer or 0
	self.SleepDt = 1
	self.SleepSpeedScale = 1
	self.PositionCorrection = 0
	self.SolverVelocity0 = self.SolverVelocity0 or Vec3()
	self.SolverAngularVelocity0 = self.SolverAngularVelocity0 or Vec3()
	self.AccumulatedForce = self.AccumulatedForce or Vec3()
	self.AccumulatedTorque = self.AccumulatedTorque or Vec3()
	self:ResetGroundSupport()
	self.Colliders = nil
	self:RebuildColliders()
	self:RefreshMassProperties()

	if self.Owner and self.Owner.transform then
		self:SynchronizeFromTransform()
	end

	self:MarkTransformDirty()
	self:OnActivityChanged()
end

function RigidBody:OnMotionTypeChanged()
	self:RefreshMassProperties()
	islands.RemoveBody(self)
	self:OnActivityChanged()
end

function RigidBody:GetCollisionProbeDistance()
	local distance = self.CollisionProbeDistance

	if distance ~= nil then return distance end

	return self:GetShapeType() == "capsule" and 0.125 or 0
end

function RigidBody:GetOwner()
	return self.Owner
end

function RigidBody:ResetGroundSupport()
	self.GroundSupportCount = 0
	self.GroundSupportMinU = math.huge
	self.GroundSupportMaxU = -math.huge
	self.GroundSupportMinV = math.huge
	self.GroundSupportMaxV = -math.huge
end

function RigidBody:AccumulateGroundSupportContact(normal, point)
	if self.GroundSupportCount == 0 then
		if not self.GroundSupportNormal then
			self.GroundSupportNormal = Vec3()
			self.GroundSupportPoint = Vec3()
			self.GroundSupportTangent = Vec3()
			self.GroundSupportBitangent = Vec3()
		end

		if
			not build_ground_support_basis(normal, self.GroundSupportTangent, self.GroundSupportBitangent)
		then
			return
		end

		self.GroundSupportNormal:CopyFrom(normal)
		self.GroundSupportPoint:CopyFrom(point)
	end

	local origin = self.GroundSupportPoint
	local dx = point.x - origin.x
	local dy = point.y - origin.y
	local dz = point.z - origin.z
	local tangent = self.GroundSupportTangent
	local bitangent = self.GroundSupportBitangent
	local u = dx * tangent.x + dy * tangent.y + dz * tangent.z
	local v = dx * bitangent.x + dy * bitangent.y + dz * bitangent.z
	self.GroundSupportMinU = math.min(self.GroundSupportMinU, u)
	self.GroundSupportMaxU = math.max(self.GroundSupportMaxU, u)
	self.GroundSupportMinV = math.min(self.GroundSupportMinV, v)
	self.GroundSupportMaxV = math.max(self.GroundSupportMaxV, v)
	self.GroundSupportCount = self.GroundSupportCount + 1
end

function RigidBody:GetGroundSupportMetrics()
	local metrics = self._GroundSupportMetrics

	if not metrics then
		metrics = {overhang = Vec3()}
		self._GroundSupportMetrics = metrics
	end

	local count = self.GroundSupportCount or 0
	metrics.count = count
	metrics.projected_u = nil
	metrics.projected_v = nil
	metrics.clamped_u = nil
	metrics.clamped_v = nil
	metrics.overhang_u = nil
	metrics.overhang_v = nil
	metrics.overhang_length = nil
	metrics.tangent = nil
	metrics.bitangent = nil
	metrics.has_overhang = false

	if count <= 0 then
		metrics.min_u = 0
		metrics.max_u = 0
		metrics.min_v = 0
		metrics.max_v = 0
		metrics.span_u = 0
		metrics.span_v = 0
		metrics.max_span = 0
		metrics.normal = nil
		metrics.point = nil
		return metrics
	end

	local min_u = self.GroundSupportMinU
	local max_u = self.GroundSupportMaxU
	local min_v = self.GroundSupportMinV
	local max_v = self.GroundSupportMaxV
	local span_u = math.max(0, max_u - min_u)
	local span_v = math.max(0, max_v - min_v)
	metrics.min_u = min_u
	metrics.max_u = max_u
	metrics.min_v = min_v
	metrics.max_v = max_v
	metrics.span_u = span_u
	metrics.span_v = span_v
	metrics.max_span = math.max(span_u, span_v)
	metrics.normal = self.GroundSupportNormal
	metrics.point = self.GroundSupportPoint
	return metrics
end

function RigidBody:GetGroundSupportProjectionMetrics()
	local support = self:GetGroundSupportMetrics()

	if support.count <= 0 then return support end

	local tangent = self.GroundSupportTangent
	local bitangent = self.GroundSupportBitangent
	local point = support.point
	local position = self.Position
	local dx = position.x - point.x
	local dy = position.y - point.y
	local dz = position.z - point.z
	local projected_u = dx * tangent.x + dy * tangent.y + dz * tangent.z
	local projected_v = dx * bitangent.x + dy * bitangent.y + dz * bitangent.z
	local clamped_u = math.max(support.min_u, math.min(support.max_u, projected_u))
	local clamped_v = math.max(support.min_v, math.min(support.max_v, projected_v))
	local overhang_u = projected_u - clamped_u
	local overhang_v = projected_v - clamped_v
	local overhang = support.overhang
	overhang.x = tangent.x * overhang_u + bitangent.x * overhang_v
	overhang.y = tangent.y * overhang_u + bitangent.y * overhang_v
	overhang.z = tangent.z * overhang_u + bitangent.z * overhang_v
	support.projected_u = projected_u
	support.projected_v = projected_v
	support.clamped_u = clamped_u
	support.clamped_v = clamped_v
	support.overhang_u = overhang_u
	support.overhang_v = overhang_v
	support.has_overhang = true
	support.overhang_length = math.sqrt(overhang.x * overhang.x + overhang.y * overhang.y + overhang.z * overhang.z)
	support.tangent = tangent
	support.bitangent = bitangent
	return support
end

function RigidBody:IsGroundSupportStable()
	local support = self:GetGroundSupportProjectionMetrics()

	if not self:GetGrounded() or support.count <= 0 then return false, support end

	return (
			support.overhang_length or
			math.huge
		) <= math.max(
			(self:GetCollisionMargin() or 0) * 2,
			(self:GetCollisionProbeDistance() or 0) * 0.5,
			0.1
		),
	support
end

function RigidBody:RebuildColliders()
	self._SupportEntryList = nil
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

RigidBody.WorldGeometryBodies = {}

local function remove_world_geometry_body(body)
	local bodies = RigidBody.WorldGeometryBodies

	for i = 1, #bodies do
		if bodies[i] == body then
			table.remove(bodies, i)
			return
		end
	end
end

function RigidBody:OnWorldGeometryChanged()
	remove_world_geometry_body(self)

	if self.WorldGeometry == true then
		local bodies = RigidBody.WorldGeometryBodies
		bodies[#bodies + 1] = self
	end
end

function RigidBody:OnRemove()
	local removed = RigidBody.RemovedBodies
	removed[#removed + 1] = self
	self:OnActivityChanged()
	islands.RemoveBody(self)
	remove_world_geometry_body(self)
end

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
	self:ComputeMassProperties()
	self:OnActivityChanged()

	if self.LockRotation then self.InverseInertiaTensor = new_zero_matrix() end
end

function RigidBody:ComputeMassProperties()
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

	if self.Inertia then
		self.InertiaTensor = Matrix33():SetDiagonal(self.Inertia.x, self.Inertia.y, self.Inertia.z)
		self.InverseInertiaTensor = get_inverse_tensor(self.InertiaTensor)
		return
	end

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
	return RigidBody.Physics
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

function RigidBody:GetUp()
	return self:GetRotation():GetUp()
end

function RigidBody:GetRight()
	return self:GetRotation():GetRight()
end

function RigidBody:GetForward()
	return self:GetRotation():GetForward()
end

function RigidBody:GetBack()
	return self:GetRotation():GetBack()
end

function RigidBody:GetGroundNormal()
	return self.GroundNormal
end

function RigidBody:SetGroundNormal(vec)
	self.GroundNormal:CopyFrom(vec)
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

	if not self.Awake then
		self.Awake = true
		RigidBody.ActivityEpoch = RigidBody.ActivityEpoch + 1
		self.SleepTimer = 0
		self.ReadyToSleepPass = nil
		stats:Count("woken_bodies")
	end
end

function RigidBody:Sleep()
	if not self:HasSolverMass() then return end

	if self.Awake then
		stats:Count("slept_bodies")
		RigidBody.ActivityEpoch = RigidBody.ActivityEpoch + 1
		self:MarkTransformDirty()
	end

	self.Awake = false
	self.SleepTimer = 0
	self.ReadyToSleepPass = nil
	self.Velocity:Set(0, 0, 0)
	self.AngularVelocity:Set(0, 0, 0)
	self.PreviousPosition:CopyFrom(self.Position)
	self.PreviousRotation:CopyFrom(self.Rotation)
end

local UPDATE_DELTA = Quat()
local UPDATE_CONJUGATE = Quat()
local SLEEP_REFERENCE_GRAVITY = 28

local function get_sleep_state_metrics(self)
	local linear_speed = self.Velocity:GetLength()
	local angular_speed = self.AngularVelocity:GetLength()
	local inverse_dt = 0.5 / self.SleepDt
	local dx = self.Position.x - self.PreviousPosition.x
	local dy = self.Position.y - self.PreviousPosition.y
	local dz = self.Position.z - self.PreviousPosition.z
	linear_speed = math.max(linear_speed, math.sqrt(dx * dx + dy * dy + dz * dz) * inverse_dt)
	Quat.SetConjugated(UPDATE_CONJUGATE, self.PreviousRotation)
	Quat.SetMul(UPDATE_DELTA, self.Rotation, UPDATE_CONJUGATE)
	angular_speed = math.max(
		angular_speed,
		2 * math.sqrt(
				UPDATE_DELTA.x * UPDATE_DELTA.x + UPDATE_DELTA.y * UPDATE_DELTA.y + UPDATE_DELTA.z * UPDATE_DELTA.z
			) * 2 * inverse_dt
	)

	local linear_threshold = self.SleepLinearThreshold * self.SleepSpeedScale
	local angular_threshold = self.SleepAngularThreshold * self.SleepSpeedScale
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
			self:IsGroundSupportStable() and
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

do
	local cycle_guard_hits = 0
	local sleep_pass = 0
	local sleep_pass_active = false

	function RigidBody.BeginSleepPass()
		sleep_pass = sleep_pass + 1
		sleep_pass_active = true
	end

	function RigidBody.EndSleepPass()
		sleep_pass_active = false
	end

	function RigidBody:IsReadyToSleep()
		if not self:HasSolverMass() or not self.CanSleep then return false, false end

		if not self.Awake then return true, false end

		if self._evaluating_ready_to_sleep then
			cycle_guard_hits = cycle_guard_hits + 1
			return false, false
		end

		if sleep_pass_active and self.ReadyToSleepPass == sleep_pass then
			return self.ReadyToSleepValue, self.ReadyToSleepForced
		end

		local guard_hits_before = cycle_guard_hits
		self._evaluating_ready_to_sleep = true
		local linear_speed, angular_speed, linear_threshold, angular_threshold, force_grounded_sleep = get_sleep_state_metrics(self)
		self._evaluating_ready_to_sleep = nil
		local ready = force_grounded_sleep or
			(
				linear_speed <= linear_threshold and
				angular_speed <= angular_threshold
			)

		if ready and not force_grounded_sleep and self.Grounded then
			local shape = self:GetPhysicsShape()
			ready = not shape or shape:CanRestOnSupport(self)
		end

		if sleep_pass_active and cycle_guard_hits == guard_hits_before then
			self.ReadyToSleepPass = sleep_pass
			self.ReadyToSleepValue = ready
			self.ReadyToSleepForced = force_grounded_sleep
		end

		return ready, force_grounded_sleep
	end
end

function RigidBody:CanSleepNow()
	if not self:HasSolverMass() or not self.CanSleep then return false, false end

	if not self.Awake then return true, false end

	local ready_to_sleep, force_grounded_sleep = self:IsReadyToSleep()

	if not ready_to_sleep then return false, force_grounded_sleep end

	return self.SleepTimer >= get_effective_sleep_delay(self, force_grounded_sleep),
	force_grounded_sleep
end

function RigidBody:UpdateSleepState(dt, defer_sleep)
	if not self:HasSolverMass() or not self.CanSleep then return end

	if not self.Awake then
		self.Velocity:Set(0, 0, 0)
		self.AngularVelocity:Set(0, 0, 0)
		self.PreviousPosition:CopyFrom(self.Position)
		self.PreviousRotation:CopyFrom(self.Rotation)
		return
	end

	local ready_to_sleep, force_grounded_sleep = self:IsReadyToSleep()

	if force_grounded_sleep and not defer_sleep then
		self:Sleep()
		return
	end

	if ready_to_sleep then
		self.SleepTimer = self.SleepTimer + dt

		if not defer_sleep and self.SleepTimer >= get_effective_sleep_delay(self) then
			self:Sleep()
		end
	else
		self.SleepTimer = 0
	end
end

local DEFAULT_HALF_EXTENTS = Vec3(0.5, 0.5, 0.5)

function RigidBody:GetHalfExtents()
	local bounds = self.LocalBounds

	if not bounds then
		local min_bounds, max_bounds = get_bounds_from_points(self:GetCollisionLocalPoints())

		if not (min_bounds and max_bounds) then return DEFAULT_HALF_EXTENTS end

		bounds = {min = min_bounds, max = max_bounds, half = (max_bounds - min_bounds) * 0.5}
		self.LocalBounds = bounds
	end

	return bounds.half
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

function RigidBody:IgnoreCollisionWith(body)
	self.IgnoredBodies = self.IgnoredBodies or table.weak("k")
	self.IgnoredBodies[body] = (self.IgnoredBodies[body] or 0) + 1
	body.IgnoredBodies = body.IgnoredBodies or table.weak("k")
	body.IgnoredBodies[self] = (body.IgnoredBodies[self] or 0) + 1
end

function RigidBody:RestoreCollisionWith(body)
	self.IgnoredBodies[body] = self.IgnoredBodies[body] - 1

	if self.IgnoredBodies[body] == 0 then self.IgnoredBodies[body] = nil end

	body.IgnoredBodies[self] = body.IgnoredBodies[self] - 1

	if body.IgnoredBodies[self] == 0 then body.IgnoredBodies[self] = nil end
end

function RigidBody:ShouldCollide(body)
	if self == body then return false end

	if self.IgnoredBodies and self.IgnoredBodies[body] then return false end

	local group_a = self.CollisionGroup or 1
	local group_b = body.CollisionGroup or 1
	local mask_a = self.CollisionMask
	local mask_b = body.CollisionMask
	mask_a = mask_a == nil and -1 or mask_a
	mask_b = mask_b == nil and -1 or mask_b
	return bit.band(mask_a, group_b) ~= 0 and bit.band(mask_b, group_a) ~= 0
end

function RigidBody:SynchronizeFromTransform()
	local transform = self.Owner and self.Owner.transform

	if not transform then return end

	if self:IsKinematic() then
		self.PreviousPosition:CopyFrom(self.Position)
		self.PreviousRotation:CopyFrom(self.Rotation)
		self.Position:CopyFrom(transform:GetPosition())
		self.Rotation:CopyFrom(transform:GetRotation())
	else
		self.Position:CopyFrom(transform:GetPosition())
		self.Rotation:CopyFrom(transform:GetRotation())
		self.PreviousPosition:CopyFrom(self.Position)
		self.PreviousRotation:CopyFrom(self.Rotation)
	end
end

function RigidBody:WriteToTransform()
	local transform = self.Owner and self.Owner.transform

	if not transform then return end

	local position = self.Position
	local rotation = self.Rotation
	local transform_position = transform:GetPosition()
	local transform_rotation = transform:GetRotation()

	if
		transform_position.x ~= position.x or
		transform_position.y ~= position.y or
		transform_position.z ~= position.z
	then
		transform:SetPosition(position:Copy())
	end

	if
		transform_rotation.x ~= rotation.x or
		transform_rotation.y ~= rotation.y or
		transform_rotation.z ~= rotation.z or
		transform_rotation.w ~= rotation.w
	then
		transform:SetRotation(rotation:Copy())
	end
end

function RigidBody:ShouldInterpolateTransform()
	return self:IsDynamic() and
		self.StepStartPosition and
		self.StepStartRotation and
		self.Position and
		self.Rotation
end

function RigidBody:GetInterpolatedPosition(alpha)
	if not self:ShouldInterpolateTransform() then return self.Position end

	return self.StepStartPosition:GetLerped(math.clamp(alpha or 0, 0, 1), self.Position)
end

function RigidBody:GetInterpolatedRotation(alpha)
	if not self:ShouldInterpolateTransform() then return self.Rotation end

	return self.StepStartRotation:Interpolate(self.Rotation, math.clamp(alpha or 0, 0, 1))
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
	local tx = 2 * (-rotation.y * dz + rotation.z * dy)
	local ty = 2 * (-rotation.z * dx + rotation.x * dz)
	local tz = 2 * (-rotation.x * dy + rotation.y * dx)
	out = out or Vec3()
	out.x = dx + rotation.w * tx + (-rotation.y * tz + rotation.z * ty)
	out.y = dy + rotation.w * ty + (-rotation.z * tx + rotation.x * tz)
	out.z = dz + rotation.w * tz + (-rotation.x * ty + rotation.y * tx)
	return out
end

local rigid_body_aabb_position = Vec3(0, 0, 0)
local collider_aabb_position = Vec3(0, 0, 0)
local collider_aabb_rotation = Quat(0, 0, 0, 1)
local collider_aabb_bounds = AABB(0, 0, 0, 0, 0, 0)

function RigidBody:GetBroadphaseAABB(position, rotation, out)
	position = position or self.Position
	rotation = rotation or self.Rotation
	local colliders = self:GetColliders()

	if #colliders == 1 then
		local collider = colliders[1]
		local local_position = collider:GetLocalPosition()
		local local_rotation = collider:GetLocalRotation()

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

	if #colliders == 0 then
		out = out or AABB(0, 0, 0, 0, 0, 0)
		out.min_x = position.x - 0.5
		out.min_y = position.y - 0.5
		out.min_z = position.z - 0.5
		out.max_x = position.x + 0.5
		out.max_y = position.y + 0.5
		out.max_z = position.z + 0.5
		return out
	end

	out = out or AABB(0, 0, 0, 0, 0, 0)
	out.min_x = math.huge
	out.min_y = math.huge
	out.min_z = math.huge
	out.max_x = -math.huge
	out.max_y = -math.huge
	out.max_z = -math.huge

	for i = 1, #colliders do
		Quat.SetVecMul(collider_aabb_position, rotation, colliders[i]:GetLocalPosition())
		collider_aabb_position.x = collider_aabb_position.x + position.x
		collider_aabb_position.y = collider_aabb_position.y + position.y
		collider_aabb_position.z = collider_aabb_position.z + position.z
		Quat.SetMul(collider_aabb_rotation, rotation, colliders[i]:GetLocalRotation()):Normalize()
		colliders[i]:GetBroadphaseAABB(collider_aabb_position, collider_aabb_rotation, collider_aabb_bounds)

		if collider_aabb_bounds.min_x < out.min_x then
			out.min_x = collider_aabb_bounds.min_x
		end

		if collider_aabb_bounds.min_y < out.min_y then
			out.min_y = collider_aabb_bounds.min_y
		end

		if collider_aabb_bounds.min_z < out.min_z then
			out.min_z = collider_aabb_bounds.min_z
		end

		if collider_aabb_bounds.max_x > out.max_x then
			out.max_x = collider_aabb_bounds.max_x
		end

		if collider_aabb_bounds.max_y > out.max_y then
			out.max_y = collider_aabb_bounds.max_y
		end

		if collider_aabb_bounds.max_z > out.max_z then
			out.max_z = collider_aabb_bounds.max_z
		end
	end

	return out
end

function RigidBody:Integrate(dt, gravity)
	self.StepDt = dt
	self.SleepSpeedScale = math.sqrt(gravity:GetLength() / SLEEP_REFERENCE_GRAVITY)
	self.PreviousPosition:CopyFrom(self.Position)
	self.PreviousRotation:CopyFrom(self.Rotation)

	if self:IsKinematic() then return end

	if not self:HasSolverMass() or not self.Awake then return end

	self.Velocity:AddScaled(gravity, self.GravityScale * dt)
	self.Velocity:AddScaled(self.AccumulatedForce, self.InverseMass * dt)
	TEMPORARY_TORQUE:CopyFrom(self.AccumulatedTorque):Scale(dt)
	self.AngularVelocity:Add(self:GetAngularVelocityDelta(TEMPORARY_TORQUE))
	self.Velocity = clamp_vec_length(self.Velocity, self.MaxLinearSpeed)
	self.AngularVelocity = clamp_vec_length(self.AngularVelocity, self.MaxAngularSpeed)
	self.SolverVelocity0:CopyFrom(self.Velocity)
	self.SolverAngularVelocity0:CopyFrom(self.AngularVelocity)
	self.HasSolverVelocity0 = true
	self.Position:AddScaled(self.Velocity, dt)
	self.Rotation = integrate_rotation(self.Rotation, self.AngularVelocity, dt)
end

local SOLVER_ANGULAR_DELTA = Vec3()

function RigidBody:SyncSolverVelocity()
	if not self.HasSolverVelocity0 then return end

	self.SolverVelocity0:CopyFrom(self.Velocity)
	self.SolverAngularVelocity0:CopyFrom(self.AngularVelocity)
end

function RigidBody:ApplySolverVelocityDelta(dt)
	if not self.HasSolverVelocity0 then return end

	self.HasSolverVelocity0 = false
	local velocity = self.Velocity
	local velocity_0 = self.SolverVelocity0
	local position = self.Position
	position.x = position.x + (velocity.x - velocity_0.x) * dt
	position.y = position.y + (velocity.y - velocity_0.y) * dt
	position.z = position.z + (velocity.z - velocity_0.z) * dt
	local delta = SOLVER_ANGULAR_DELTA
	delta.x = self.AngularVelocity.x - self.SolverAngularVelocity0.x
	delta.y = self.AngularVelocity.y - self.SolverAngularVelocity0.y
	delta.z = self.AngularVelocity.z - self.SolverAngularVelocity0.z
	self.Rotation = integrate_rotation(self.Rotation, delta, dt)
end

function RigidBody:UpdateVelocities(dt)
	if self:IsKinematic() then
		self.Velocity:CopyFrom(self.Position):Sub(self.PreviousPosition):Scale(1 / dt)
		Quat.SetConjugated(UPDATE_CONJUGATE, self.PreviousRotation)
		Quat.SetMul(UPDATE_DELTA, self.Rotation, UPDATE_CONJUGATE)
		UPDATE_DELTA:Normalize()
		self.AngularVelocity:Set(UPDATE_DELTA.x * 2 / dt, UPDATE_DELTA.y * 2 / dt, UPDATE_DELTA.z * 2 / dt)

		if UPDATE_DELTA.w < 0 then self.AngularVelocity:Scale(-1) end

		self.PreviousPosition:CopyFrom(self.Position)
		self.PreviousRotation:CopyFrom(self.Rotation)
		return
	end

	if not self:HasSolverMass() then
		self.Velocity:Set(0, 0, 0)
		self.AngularVelocity:Set(0, 0, 0)
		return
	end

	if not self.Awake then
		self.Velocity:Set(0, 0, 0)
		self.AngularVelocity:Set(0, 0, 0)
		self.PreviousPosition:CopyFrom(self.Position)
		self.PreviousRotation:CopyFrom(self.Rotation)
		return
	end

	self.ReadyToSleepPass = nil
	self.SleepDt = dt
	local ground_body = self.GroundBody

	if self.Grounded and not (ground_body and ground_body:HasSolverMass()) then
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

function RigidBody:_ApplyAngularCorrection(world_angle_impulse)
	if not self:HasSolverMass() then return end

	motion.IntegrateRotation(self.Rotation, self:GetAngularVelocityDelta(world_angle_impulse), 1)
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

	if not self.Awake and CORRECTION_DIFF:GetLength() > 0.001 then self:Wake() end

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
return RigidBody
