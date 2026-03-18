local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local META = {}
local METHODS = {}

local function copy_position(position)
	if position and position.Copy then return position:Copy() end

	return Vec3()
end

local function copy_rotation(rotation)
	if rotation and rotation.Copy then return rotation:Copy() end

	return Quat():Identity()
end

local function get_override(self, key, fallback)
	local value = rawget(self, key)

	if value ~= nil then return value end

	return fallback
end

function META.New(body, data, index)
	local self = {}
	self.Body = body
	self.ColliderIndex = index or 1
	self.Shape = assert(data.Shape or data.shape, "collider requires Shape")
	self.LocalPosition = copy_position(data.Position or data.position)
	self.LocalRotation = copy_rotation(data.Rotation or data.rotation)

	for _, key in ipairs{
		"Density",
		"Mass",
		"AutomaticMass",
		"CollisionGroup",
		"CollisionMask",
		"CollisionMargin",
		"CollisionProbeDistance",
		"Friction",
		"RollingFriction",
		"Restitution",
		"FrictionCombineMode",
		"RollingFrictionCombineMode",
		"RestitutionCombineMode",
		"FilterFunction",
		"MinGroundNormalY",
	} do
		if data[key] ~= nil then self[key] = data[key] end
	end

	return setmetatable(self, META)
end

function META:__index(key)
	local method = METHODS[key]

	if method ~= nil then return method end

	if key == "Position" then return self:GetPosition() end

	if key == "PreviousPosition" then return self:GetPreviousPosition() end

	if key == "Rotation" then return self:GetRotation() end

	if key == "PreviousRotation" then return self:GetPreviousRotation() end

	if key == "InverseMass" or key == "Owner" then return self.Body[key] end

	return self.Body[key]
end

function META:__newindex(key, value)
	if key == "Position" then
		local current = self:GetPosition()
		self.Body.Position = self.Body.Position + (value - current)
		return
	end

	if key == "PreviousPosition" then
		local current = self:GetPreviousPosition()
		self.Body.PreviousPosition = self.Body.PreviousPosition + (value - current)
		return
	end

	if key == "Rotation" then
		self.Body.Rotation = (value * self.LocalRotation:GetConjugated()):GetNormalized()
		return
	end

	if key == "PreviousRotation" then
		self.Body.PreviousRotation = (value * self.LocalRotation:GetConjugated()):GetNormalized()
		return
	end

	rawset(self, key, value)
end

function METHODS:InvalidateGeometry()
	self.CollisionLocalPoints = nil
	self.SupportLocalPoints = nil

	if self.Shape and self.Shape.OnBodyGeometryChanged then
		self.Shape:OnBodyGeometryChanged(self)
	end

	return self
end

function METHODS:GetBody()
	return self.Body
end

function METHODS:GetOwner()
	return self.Body:GetOwner()
end

function METHODS:GetLocalPosition()
	return self.LocalPosition
end

function METHODS:GetLocalRotation()
	return self.LocalRotation
end

function METHODS:GetPhysicsShape()
	return self.Shape
end

function METHODS:GetShapeType()
	return self.Shape and self.Shape.GetTypeName and self.Shape:GetTypeName() or "unknown"
end

function METHODS:GetResolvedConvexHull()
	return self.Shape and
		self.Shape.GetResolvedHull and
		self.Shape:GetResolvedHull(self) or
		nil
end

function METHODS:GetDensity()
	return get_override(self, "Density", self.Body:GetDensity())
end

function METHODS:GetMass()
	return get_override(self, "Mass", self.Body:GetMass())
end

function METHODS:GetAutomaticMass()
	return get_override(self, "AutomaticMass", self.Body:GetAutomaticMass())
end

function METHODS:GetCollisionGroup()
	return get_override(self, "CollisionGroup", self.Body:GetCollisionGroup())
end

function METHODS:GetCollisionMask()
	return get_override(self, "CollisionMask", self.Body:GetCollisionMask())
end

function METHODS:GetCollisionMargin()
	return get_override(self, "CollisionMargin", self.Body:GetCollisionMargin())
end

function METHODS:GetCollisionProbeDistance()
	return get_override(self, "CollisionProbeDistance", self.Body:GetCollisionProbeDistance())
end

function METHODS:GetFriction()
	return get_override(self, "Friction", self.Body:GetFriction())
end

function METHODS:GetRollingFriction()
	return get_override(self, "RollingFriction", self.Body:GetRollingFriction())
end

function METHODS:GetRestitution()
	return get_override(self, "Restitution", self.Body:GetRestitution())
end

function METHODS:GetFrictionCombineMode()
	return get_override(self, "FrictionCombineMode", self.Body:GetFrictionCombineMode())
end

function METHODS:GetRollingFrictionCombineMode()
	return get_override(self, "RollingFrictionCombineMode", self.Body:GetRollingFrictionCombineMode())
end

function METHODS:GetRestitutionCombineMode()
	return get_override(self, "RestitutionCombineMode", self.Body:GetRestitutionCombineMode())
end

function METHODS:GetFilterFunction()
	return get_override(self, "FilterFunction", self.Body:GetFilterFunction())
end

function METHODS:GetMinGroundNormalY()
	return get_override(self, "MinGroundNormalY", self.Body:GetMinGroundNormalY())
end

function METHODS:GetGroundRollingFriction()
	return self.Body:GetGroundRollingFriction()
end

function METHODS:SetGroundRollingFriction(value)
	return self.Body:SetGroundRollingFriction(value)
end

function METHODS:GetGrounded()
	return self.Body:GetGrounded()
end

function METHODS:SetGrounded(grounded)
	return self.Body:SetGrounded(grounded)
end

function METHODS:GetGroundNormal()
	return self.Body:GetGroundNormal()
end

function METHODS:SetGroundNormal(normal)
	return self.Body:SetGroundNormal(normal)
end

function METHODS:GetVelocity()
	return self.Body:GetVelocity()
end

function METHODS:SetVelocity(vec)
	return self.Body:SetVelocity(vec)
end

function METHODS:GetAngularVelocity()
	return self.Body:GetAngularVelocity()
end

function METHODS:SetAngularVelocity(vec)
	return self.Body:SetAngularVelocity(vec)
end

function METHODS:GetPosition()
	return self.Body:GetPosition() + self.Body:GetRotation():VecMul(self.LocalPosition)
end

function METHODS:GetPreviousPosition()
	return self.Body:GetPreviousPosition() + self.Body:GetPreviousRotation():VecMul(self.LocalPosition)
end

function METHODS:GetRotation()
	return (self.Body:GetRotation() * self.LocalRotation):GetNormalized()
end

function METHODS:GetPreviousRotation()
	return (self.Body:GetPreviousRotation() * self.LocalRotation):GetNormalized()
end

function METHODS:LocalToWorld(local_pos, position, rotation)
	position = position or self:GetPosition()
	rotation = rotation or self:GetRotation()
	return position + rotation:VecMul(local_pos)
end

function METHODS:GeometryLocalToWorld(local_pos, position, rotation)
	return self.Shape:GeometryLocalToWorld(self, local_pos, position, rotation)
end

function METHODS:WorldToLocal(world_pos, position, rotation)
	position = position or self:GetPosition()
	rotation = rotation or self:GetRotation()
	return rotation:GetConjugated():VecMul(world_pos - position)
end

function METHODS:GetBroadphaseAABB(position, rotation)
	return self.Shape:GetBroadphaseAABB(self, position, rotation)
end

function METHODS:BuildCollisionLocalPoints()
	return self.Shape:BuildCollisionLocalPoints(self)
end

function METHODS:GetCollisionLocalPoints()
	if not self.CollisionLocalPoints then
		self.CollisionLocalPoints = self:BuildCollisionLocalPoints()
	end

	return self.CollisionLocalPoints
end

function METHODS:BuildSupportLocalPoints()
	return self.Shape:BuildSupportLocalPoints(self)
end

function METHODS:GetSupportLocalPoints()
	if not self.SupportLocalPoints then
		self.SupportLocalPoints = self:BuildSupportLocalPoints()
	end

	return self.SupportLocalPoints
end

function METHODS:GetHalfExtents()
	return self.Shape:GetHalfExtents(self)
end

function METHODS:IsStatic()
	return self.Body:IsStatic()
end

function METHODS:IsKinematic()
	return self.Body:IsKinematic()
end

function METHODS:IsDynamic()
	return self.Body:IsDynamic()
end

function METHODS:HasSolverMass()
	return self.Body:HasSolverMass()
end

function METHODS:IsSolverImmovable()
	return self.Body:IsSolverImmovable()
end

function METHODS:Wake()
	return self.Body:Wake()
end

function METHODS:Sleep()
	return self.Body:Sleep()
end

function METHODS:GetAngularVelocityDelta(world_impulse)
	return self.Body:GetAngularVelocityDelta(world_impulse)
end

function METHODS:GetInverseMassAlong(normal, pos)
	return self.Body:GetInverseMassAlong(normal, pos)
end

function METHODS:ApplyCorrection(compliance, correction, pos, other_body, other_pos, dt)
	local other = other_body and other_body.GetBody and other_body:GetBody() or other_body
	return self.Body:ApplyCorrection(compliance, correction, pos, other, other_pos, dt)
end

function METHODS:ApplyImpulse(impulse, world_pos)
	return self.Body:ApplyImpulse(impulse, world_pos)
end

function METHODS:ApplyAngularImpulse(impulse)
	return self.Body:ApplyAngularImpulse(impulse)
end

function METHODS:ApplyForce(force, world_pos)
	return self.Body:ApplyForce(force, world_pos)
end

function METHODS:ApplyTorque(torque)
	return self.Body:ApplyTorque(torque)
end

function METHODS:GetSphereRadius()
	return self.Body:GetSphereRadius()
end

function METHODS:GetBodyPolyhedron()
	return self.Body:GetBodyPolyhedron()
end

function METHODS:BodyHasSignificantRotation()
	return self.Body:BodyHasSignificantRotation()
end

return META
