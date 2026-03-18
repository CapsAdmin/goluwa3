local physics = import("goluwa/physics.lua")
local solver = import("goluwa/physics/solver.lua")
local kinematic_controller = import("goluwa/physics/kinematic_controller.lua")
local prototype = import("goluwa/prototype.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Matrix33 = import("goluwa/structs/matrix33.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local ConvexShape = import("goluwa/physics/shapes/convex.lua")
local Collider = import("goluwa/physics/collider.lua")
local Entity = import("goluwa/ecs/entity.lua")
local default_skin = (
		import.loaded["goluwa/physics.lua"] and
		import.loaded["goluwa/physics.lua"].DefaultSkin
	)
	or
	0.02
local RigidBody = prototype.CreateTemplate("rigid_body")

do
	RigidBody:GetSet("Enabled", true)
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
	RigidBody:GetSet("CollisionGroup", 1)
	RigidBody:GetSet("CollisionMask", -1)
	RigidBody:GetSet("CollisionMargin", default_skin)
	RigidBody:GetSet("CollisionProbeDistance", 0.125)
	RigidBody:GetSet("Friction", 0)
	RigidBody:GetSet("RollingFriction", 0)
	RigidBody:GetSet("Restitution", 0)
	RigidBody:GetSet("FrictionCombineMode", nil)
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

	local function copy_position(position)
		if position and position.Copy then return position:Copy() end

		return Vec3()
	end

	local function copy_rotation(rotation)
		if rotation and rotation.Copy then return rotation:Copy() end

		return Quat():Identity()
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
		parent_position = parent_position or Vec3()
		parent_rotation = parent_rotation or Quat():Identity()
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
				Position = Vec3(),
				Rotation = Quat():Identity(),
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

	function RigidBody:RebuildColliders()
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

			if
				allow_grounded_sleep_assist and
				shape and
				shape.SnapGroundedSleepPose and
				shape:SnapGroundedSleepPose(self)
			then
				linear_speed = self.Velocity:GetLength()
				angular_speed = self.AngularVelocity:GetLength()
			end

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

	function RigidBody:IsReadyToSleep()
		if not self:HasSolverMass() or not self.CanSleep then return false, false end

		if not self.Awake then return true, false end

		local linear_speed, angular_speed, linear_threshold, angular_threshold, force_grounded_sleep = get_sleep_state_metrics(self)

		if force_grounded_sleep then return true, true end

		return linear_speed <= linear_threshold and angular_speed <= angular_threshold,
		false
	end

	function RigidBody:CanSleepNow()
		if not self:HasSolverMass() or not self.CanSleep then return false, false end

		if not self.Awake then return true, false end

		local ready_to_sleep, force_grounded_sleep = self:IsReadyToSleep()

		if not ready_to_sleep then return false, force_grounded_sleep end

		return self.SleepTimer >= math.max(self.SleepDelay or 0, 0), force_grounded_sleep
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

			if self.SleepTimer >= math.max(self.SleepDelay or 0, 0) then self:Sleep() end
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
		return self:IsDynamic() and self.InverseMass > 0
	end

	function RigidBody:IsSolverImmovable()
		return not self:HasSolverMass()
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

function physics.UpdateRigidBodies(dt)
	if not dt or dt <= 0 then return end

	local bodies = RigidBody.Instances

	if #bodies == 0 then return end

	local substeps = math.max(1, physics.RigidBodySubsteps or 1)
	local iterations = math.max(1, physics.RigidBodyIterations or 1)
	local sub_dt = dt / substeps
	physics.BeginCollisionFrame()

	for _, body in ipairs(bodies) do
		if physics.IsActiveRigidBody(body) then body:SynchronizeFromTransform() end
	end

	for _ = 1, substeps do
		if solver.BeginStep then solver:BeginStep() end

		for _, body in ipairs(bodies) do
			if physics.IsActiveRigidBody(body) then
				if body:IsKinematic() or body:HasKinematicController() then
					kinematic_controller.UpdateBody(body, sub_dt, physics.Gravity)
				elseif body:GetAwake() then
					body:SetGrounded(false)
					body:SetGroundNormal(physics.Up)
					body:Integrate(sub_dt, physics.Gravity)
				else
					body.PreviousPosition = body.Position:Copy()
					body.PreviousRotation = body.Rotation:Copy()
				end
			end
		end

		local rigid_body_pairs = solver.BuildBroadphasePairs and solver.BuildBroadphasePairs(bodies) or bodies
		local constraints = physics.GetConstraints()
		local simulation_islands = solver.BuildSimulationIslands and
			solver.BuildSimulationIslands(bodies, rigid_body_pairs, constraints) or
			nil
		local newly_awoken_bodies = {}

		if simulation_islands and simulation_islands[1] and solver.PrepareSimulationIslands then
			local woke_any
			woke_any, newly_awoken_bodies = solver.PrepareSimulationIslands(simulation_islands, newly_awoken_bodies)

			if woke_any then
				for body_index = 1, #newly_awoken_bodies do
					local body = newly_awoken_bodies[body_index]

					if physics.IsActiveRigidBody(body) and body:GetAwake() then
						body:SetGrounded(false)
						body:SetGroundNormal(physics.Up)
						body:Integrate(sub_dt, physics.Gravity)
					end
				end

				rigid_body_pairs = solver.BuildBroadphasePairs and solver.BuildBroadphasePairs(bodies) or bodies
				simulation_islands = solver.BuildSimulationIslands and
					solver.BuildSimulationIslands(bodies, rigid_body_pairs, constraints) or
					nil

				if simulation_islands and simulation_islands[1] and solver.PrepareSimulationIslands then
					solver.PrepareSimulationIslands(simulation_islands, newly_awoken_bodies)
				end
			end
		end

		for _ = 1, iterations do
			if simulation_islands and simulation_islands[1] then
				for island_index = 1, #simulation_islands do
					local island = simulation_islands[island_index]

					if
						not (
							solver.IsSimulationIslandSleeping and
							solver.IsSimulationIslandSleeping(island)
						)
					then
						solver.SolveRigidBodyPairs(island.pairs, sub_dt)
						local dynamic_bodies = island.awake_dynamic_bodies or island.dynamic_bodies or island.bodies

						for body_index = 1, #dynamic_bodies do
							local body = dynamic_bodies[body_index]

							if physics.IsActiveRigidBody(body) then
								solver.SolveBodyContacts(body, sub_dt)
							end
						end

						solver.SolveDistanceConstraints(sub_dt, island.constraints)
					end
				end
			else
				solver.SolveRigidBodyPairs(rigid_body_pairs, sub_dt)

				for _, body in ipairs(bodies) do
					if physics.IsActiveRigidBody(body) then
						if body:IsDynamic() and body:GetAwake() then
							solver.SolveBodyContacts(body, sub_dt)
						end
					end
				end

				solver.SolveDistanceConstraints(sub_dt, constraints)
			end
		end

		for _, body in ipairs(bodies) do
			if physics.IsActiveRigidBody(body) then
				body:UpdateVelocities(sub_dt)
				body:UpdateSleepState(sub_dt)
			end
		end

		if simulation_islands and simulation_islands[1] and solver.FinalizeSimulationIslands then
			solver.FinalizeSimulationIslands(simulation_islands)
		end
	end

	for _, body in ipairs(bodies) do
		if physics.IsActiveRigidBody(body) then body:ClearAccumulators() end
	end

	for _, body in ipairs(bodies) do
		if physics.IsActiveRigidBody(body) then body:WriteToTransform() end
	end

	physics.DispatchCollisionEvents()
end

return RigidBody