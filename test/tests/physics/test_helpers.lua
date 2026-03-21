local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/ecs/entity.lua")
local MeshShape = import("goluwa/physics/shapes/mesh.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local module = {}

local function copy_position(position)
	if position and position.Copy then return position:Copy() end

	return Vec3()
end

local function copy_rotation(rotation)
	if rotation and rotation.Copy then return rotation:Copy() end

	return Quat():Identity()
end

local function create_default_owner(position, rotation)
	return {
		IsValid = function()
			return true
		end,
		transform = {
			position = position:Copy(),
			rotation = rotation:Copy(),
			GetPosition = function(self)
				return self.position
			end,
			GetRotation = function(self)
				return self.rotation
			end,
			SetPosition = function(self, value)
				self.position = value
			end,
			SetRotation = function(self, value)
				self.rotation = value
			end,
		},
	}
end

function module.SimulatePhysics(physics, steps, dt)
	dt = dt or (1 / 120)

	for _ = 1, steps do
		physics.Update(dt)
	end
end

function module.AttachWorldGeometryBody(entity, source)
	source = source or {Model = entity.model}

	local body = entity:AddComponent("rigid_body", {
		Shape = MeshShape.New(source),
		MotionType = "static",
		WorldGeometry = true,
	})
	body.WorldGeometry = true
	return body
end

function module.CreateFlatGround(name, extent)
	extent = extent or 8
	local ground = Entity.New({Name = name})
	ground:AddComponent("transform")
	local poly = Polygon3D.New()
	poly:AddVertex{pos = Vec3(-extent, 0, -extent), uv = Vec2(0, 0), normal = Vec3(0, 1, 0)}
	poly:AddVertex{pos = Vec3(0, 0, extent), uv = Vec2(0.5, 1), normal = Vec3(0, 1, 0)}
	poly:AddVertex{pos = Vec3(extent, 0, -extent), uv = Vec2(1, 0), normal = Vec3(0, 1, 0)}
	poly:BuildBoundingBox()
	module.AttachWorldGeometryBody(ground, poly)
	return ground
end

function module.AddTriangle(poly, a, b, c)
	poly:AddVertex{pos = a, uv = Vec2(0, 0)}
	poly:AddVertex{pos = b, uv = Vec2(1, 0)}
	poly:AddVertex{pos = c, uv = Vec2(0.5, 1)}
end

function module.CreateStubBody(data)
	data = data or {}
	local position = copy_position(data.Position)
	local previous_position = copy_position(data.PreviousPosition or data.Position)
	local rotation = copy_rotation(data.Rotation)
	local previous_rotation = copy_rotation(data.PreviousRotation or data.Rotation)
	local velocity = copy_position(data.Velocity)
	local angular_velocity = copy_position(data.AngularVelocity)
	local motion_type = data.MotionType or
		(
			data.IsKinematic and
			"kinematic" or
			(
				data.IsDynamic == false and
				"static" or
				"dynamic"
			)
		)
	local body = {
		Name = data.Name,
		Enabled = data.Enabled ~= false,
		CollisionEnabled = data.CollisionEnabled ~= false,
		Owner = data.Owner,
		Position = position,
		PreviousPosition = previous_position,
		Rotation = rotation,
		PreviousRotation = previous_rotation,
		Velocity = velocity,
		AngularVelocity = angular_velocity,
		InverseMass = data.InverseMass == nil and 1 or data.InverseMass,
		MotionType = motion_type,
		Awake = data.Awake,
		WakeCount = data.WakeCount or 0,
		SleepCount = data.SleepCount or 0,
		ReadyToSleep = data.ReadyToSleep == true,
		Grounded = data.Grounded == true,
		GroundNormal = copy_position(data.GroundNormal or Vec3(0, 1, 0)),
		polyhedron = data.polyhedron,
	}

	if body.Owner == nil and data.IncludeDefaultOwner ~= false then
		body.Owner = create_default_owner(position, rotation)
	end

	if body.Awake == nil then body.Awake = motion_type ~= "dynamic" end

	function body:GetMass()
		return data.Mass or 0
	end

	function body:GetDensity()
		return data.Density or 0
	end

	function body:GetAutomaticMass()
		return data.AutomaticMass == true
	end

	function body:IsDynamic()
		return self.MotionType == "dynamic"
	end

	function body:IsKinematic()
		return self.MotionType == "kinematic"
	end

	function body:IsStatic()
		return self.MotionType == "static"
	end

	function body:GetPosition()
		return self.Position
	end

	function body:GetPreviousPosition()
		return self.PreviousPosition
	end

	function body:GetRotation()
		return self.Rotation
	end

	function body:GetPreviousRotation()
		return self.PreviousRotation
	end

	function body:GetVelocity()
		return self.Velocity
	end

	function body:GetAngularVelocity()
		return self.AngularVelocity
	end

	function body:GetOwner()
		return self.Owner
	end

	function body:GetCollisionMargin()
		return data.Margin or data.CollisionMargin or 0
	end

	function body:GetCollisionProbeDistance()
		return data.CollisionProbeDistance or 0
	end

	function body:GetFilterFunction()
		return data.FilterFunction
	end

	function body:GetMinGroundNormalY()
		return data.MinGroundNormalY or 0
	end

	function body:GetGrounded()
		return self.Grounded
	end

	function body:SetGrounded(grounded)
		self.Grounded = grounded
	end

	function body:GetGroundNormal()
		return self.GroundNormal
	end

	function body:SetGroundNormal(normal)
		self.GroundNormal = normal
	end

	function body:WorldToLocal(point, position_override, rotation_override)
		local position_value = position_override or self.Position
		local rotation_value = rotation_override or self.Rotation
		return rotation_value:GetConjugated():VecMul(point - position_value)
	end

	function body:LocalToWorld(point, position_override, rotation_override)
		local position_value = position_override or self.Position
		local rotation_value = rotation_override or self.Rotation
		return position_value + rotation_value:VecMul(point)
	end

	function body:GeometryLocalToWorld(point, position_override, rotation_override)
		return self:LocalToWorld(point, position_override, rotation_override)
	end

	function body:GetInverseMassAlong()
		return self.InverseMass
	end

	function body:GetFriction()
		return data.Friction or 0
	end

	function body:GetStaticFriction()
		if data.StaticFriction ~= nil then return data.StaticFriction end

		return data.Friction or 0
	end

	function body:GetFrictionCombineMode()
		return data.FrictionCombineMode
	end

	function body:GetStaticFrictionCombineMode()
		return data.StaticFrictionCombineMode or data.FrictionCombineMode
	end

	function body:GetRestitution()
		return data.Restitution or 0
	end

	function body:GetRestitutionCombineMode()
		return data.RestitutionCombineMode
	end

	function body:GetAngularVelocityDelta()
		return data.AngularVelocityDelta and data.AngularVelocityDelta:Copy() or Vec3()
	end

	function body:IsSolverImmovable()
		return data.Immovable == true
	end

	function body:HasSolverMass()
		return self:IsDynamic() and not self:IsSolverImmovable() and self.InverseMass > 0
	end

	function body:GetAwake()
		return self.Awake
	end

	function body:Wake()
		self.Awake = true
		self.WakeCount = self.WakeCount + 1
		return self
	end

	function body:Sleep()
		self.Awake = false
		self.SleepCount = self.SleepCount + 1
		return self
	end

	function body:IsReadyToSleep()
		return self.ReadyToSleep or not self.Awake
	end

	function body:GetSleepDelay()
		return self.SleepDelay or 0
	end

	function body:CanSleepNow()
		if not self:IsReadyToSleep() then return false end
		if not self:GetAwake() then return true end
		return math.max(self.SleepTimer or 0, 0) >= math.max(self:GetSleepDelay(), 0)
	end

	function body:ApplyImpulse(impulse, point)
		if self:IsSolverImmovable() then return self end

		self.Velocity = self.Velocity + impulse * self.InverseMass

		if point then
			self.AngularVelocity = self.AngularVelocity + self:GetAngularVelocityDelta((point - self.Position):GetCross(impulse))
		end

		return self
	end

	function body:GetShapeType()
		return data.ShapeType
	end

	function body:GetSphereRadius()
		return data.Radius or 0
	end

	function body:GetBodyPolyhedron()
		return self.polyhedron
	end

	function body:BodyHasSignificantRotation()
		return data.HasSignificantRotation == true
	end

	return body
end

function module.CreateTestRigidBody(data)
	data = data or {}
	local physics = import("goluwa/physics.lua")
	local RigidBody = import("goluwa/physics/rigid_body.lua")
	local SphereShape = import("goluwa/physics/shapes/sphere.lua")
	local radius = data.Radius or 0.1
	local margin = data.Margin or 0.01
	local position = copy_position(data.Position)
	local previous_position = copy_position(data.PreviousPosition or data.Position)
	local rotation = copy_rotation(data.Rotation)
	local previous_rotation = copy_rotation(data.PreviousRotation or data.Rotation)
	local velocity = copy_position(data.Velocity)
	local angular_velocity = copy_position(data.AngularVelocity)
	local body = RigidBody:CreateObject{
		CollisionEnabled = data.CollisionEnabled ~= false,
		Shape = data.Shape or SphereShape.New(radius),
		Position = position,
		PreviousPosition = previous_position,
		Rotation = rotation,
		PreviousRotation = previous_rotation,
		Velocity = velocity,
		AngularVelocity = angular_velocity,
		Grounded = data.Grounded == true,
		GroundNormal = copy_position(data.GroundNormal or physics.Up or Vec3(0, 1, 0)),
	}
	body:Initialize()
	body.Owner = data.Owner or create_default_owner(position, rotation)
	body.CorrectionCount = data.CorrectionCount or 0
	body:SetCollisionMargin(margin)
	body:SetCollisionProbeDistance(data.CollisionProbeDistance or 0)
	body:SetMinGroundNormalY(data.MinGroundNormalY or 0.7)
	body:RebuildColliders()

	function body:ApplyCorrection(_, _, point)
		self.CorrectionCount = self.CorrectionCount + 1
		self.LastCorrectionPoint = point and point:Copy() or nil
		return self
	end

	function body:HasSolverMass()
		return false
	end

	function body:ApplyImpulse() end

	function body:GetInverseMassAlong()
		return 0
	end

	function body:GetFriction()
		return data.Friction or 0
	end

	function body:GetStaticFriction()
		if data.StaticFriction ~= nil then return data.StaticFriction end

		return data.Friction or 0
	end

	return body
end

return module
