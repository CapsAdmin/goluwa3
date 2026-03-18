local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local prototype = import("goluwa/prototype.lua")
local META = prototype.CreateTemplate("physics_collider")

function META.New(body, data, index)
	local self = {}
	self.Body = body
	self.ColliderIndex = index or 1
	self.Shape = assert(data.Shape or data.shape, "collider requires Shape")
	self.LocalPosition = data.Position:Copy()
	self.LocalRotation = data.Rotation:Copy()

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

	return META:CreateObject(self)
end

function META:__index2(key)
	local method = META[key]

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

function META:InvalidateGeometry()
	self.CollisionLocalPoints = nil
	self.SupportLocalPoints = nil

	if self.Shape and self.Shape.OnBodyGeometryChanged then
		self.Shape:OnBodyGeometryChanged(self)
	end

	return self
end

function META:GetBody()
	return self.Body
end

function META:GetOwner()
	return self.Body:GetOwner()
end

function META:GetLocalPosition()
	return self.LocalPosition
end

function META:GetLocalRotation()
	return self.LocalRotation
end

function META:GetPhysicsShape()
	return self.Shape
end

function META:GetShapeType()
	return self.Shape and self.Shape.GetTypeName and self.Shape:GetTypeName() or "unknown"
end

function META:GetResolvedConvexHull()
	return self.Shape and
		self.Shape.GetResolvedHull and
		self.Shape:GetResolvedHull(self) or
		nil
end

for _, name in ipairs{
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
	local body_getter_name = "Get" .. name
	META[body_getter_name] = function(self)
		local value = rawget(self, body_getter_name)

		if value ~= nil then return value end

		return self.Body[body_getter_name](self.Body)
	end
end

for _, name in ipairs{
	"GetOwner",
	"GetGroundRollingFriction",
	"SetGroundRollingFriction",
	"GetGrounded",
	"SetGrounded",
	"GetGroundNormal",
	"SetGroundNormal",
	"GetVelocity",
	"SetVelocity",
	"GetAngularVelocity",
	"SetAngularVelocity",
	"IsStatic",
	"IsKinematic",
	"IsDynamic",
	"HasSolverMass",
	"IsSolverImmovable",
	"Wake",
	"Sleep",
	"GetAngularVelocityDelta",
	"GetInverseMassAlong",
	"ApplyImpulse",
	"ApplyAngularImpulse",
	"ApplyForce",
	"ApplyTorque",
	"GetSphereRadius",
	"GetBodyPolyhedron",
	"BodyHasSignificantRotation",
} do
	prototype.Delegate(META, "Body", name)
end

function META:GetPosition()
	return self.Body:GetPosition() + self.Body:GetRotation():VecMul(self.LocalPosition)
end

function META:GetPreviousPosition()
	return self.Body:GetPreviousPosition() + self.Body:GetPreviousRotation():VecMul(self.LocalPosition)
end

function META:GetRotation()
	return (self.Body:GetRotation() * self.LocalRotation):GetNormalized()
end

function META:GetPreviousRotation()
	return (self.Body:GetPreviousRotation() * self.LocalRotation):GetNormalized()
end

function META:LocalToWorld(local_pos, position, rotation)
	position = position or self:GetPosition()
	rotation = rotation or self:GetRotation()
	return position + rotation:VecMul(local_pos)
end

function META:GeometryLocalToWorld(local_pos, position, rotation)
	return self.Shape:GeometryLocalToWorld(self, local_pos, position, rotation)
end

function META:WorldToLocal(world_pos, position, rotation)
	position = position or self:GetPosition()
	rotation = rotation or self:GetRotation()
	return rotation:GetConjugated():VecMul(world_pos - position)
end

function META:GetBroadphaseAABB(position, rotation)
	return self.Shape:GetBroadphaseAABB(self, position, rotation)
end

function META:BuildCollisionLocalPoints()
	return self.Shape:BuildCollisionLocalPoints(self)
end

function META:GetCollisionLocalPoints()
	if not self.CollisionLocalPoints then
		self.CollisionLocalPoints = self:BuildCollisionLocalPoints()
	end

	return self.CollisionLocalPoints
end

function META:BuildSupportLocalPoints()
	return self.Shape:BuildSupportLocalPoints(self)
end

function META:GetSupportLocalPoints()
	if not self.SupportLocalPoints then
		self.SupportLocalPoints = self:BuildSupportLocalPoints()
	end

	return self.SupportLocalPoints
end

function META:GetHalfExtents()
	return self.Shape:GetHalfExtents(self)
end

function META:ApplyCorrection(compliance, correction, pos, other_body, other_pos, dt)
	local other = other_body and other_body.GetBody and other_body:GetBody() or other_body
	return self.Body:ApplyCorrection(compliance, correction, pos, other, other_pos, dt)
end

return META:Register()