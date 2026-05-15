local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local prototype = import("goluwa/prototype.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local ConvexShape = import("goluwa/physics/shapes/convex.lua")
local HeightmapShape = import("goluwa/physics/shapes/heightmap.lua")
local MeshShape = import("goluwa/physics/shapes/mesh.lua")
local META = prototype.CreateTemplate("physics_collider")

local function copy_position(position)
	if position and position.Copy then return position:Copy() end

	return Vec3()
end

local function copy_rotation(rotation)
	if rotation and rotation.Copy then return rotation:Copy() end

	return Quat():Identity()
end

local function is_shape_definition(value)
	return type(value) == "table" and
		(
			value.Shape ~= nil or
			value.shape ~= nil or
			value.Heightmap ~= nil or
			value.Position ~= nil or
			value.position ~= nil or
			value.Rotation ~= nil or
			value.rotation ~= nil or
			value.ConvexHull ~= nil or
			value.TriangleMesh ~= nil or
			value.Mesh ~= nil or
			value.Polygon3D ~= nil or
			value.Primitive ~= nil or
			value.Model ~= nil or
			value.Polygons ~= nil
		)
end

local function get_shape_from_definition(data)
	local shape = data.Shape or data.shape

	if not shape and data.ConvexHull then
		shape = ConvexShape.New(data.ConvexHull)
	end

	if not shape and data.Heightmap then
		shape = HeightmapShape.New{
			Heightmap = data.Heightmap,
			Size = data.Size,
			Resolution = data.Resolution,
			Height = data.Height,
			Pow = data.Pow,
		}
	end

	if
		not shape and
		(
			data.TriangleMesh or
			data.Mesh or
			data.Polygon3D or
			data.Primitive or
			data.Model or
			data.Polygons
		)
	then
		shape = MeshShape.New{
			Source = data.TriangleMesh or data.Mesh,
			Polygon3D = data.Polygon3D,
			Primitive = data.Primitive,
			Model = data.Model,
			Polygons = data.Polygons,
		}
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
		StaticFriction = data.StaticFriction,
		RollingFriction = data.RollingFriction,
		Restitution = data.Restitution,
		FrictionCombineMode = data.FrictionCombineMode,
		StaticFrictionCombineMode = data.StaticFrictionCombineMode,
		RollingFrictionCombineMode = data.RollingFrictionCombineMode,
		RestitutionCombineMode = data.RestitutionCombineMode,
		FilterFunction = data.FilterFunction,
		MinGroundNormalY = data.MinGroundNormalY,
	}
end

function META.BuildEntries(body)
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
		"StaticFriction",
		"RollingFriction",
		"Restitution",
		"FrictionCombineMode",
		"StaticFrictionCombineMode",
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
	"StaticFriction",
	"RollingFriction",
	"Restitution",
	"FrictionCombineMode",
	"StaticFrictionCombineMode",
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

function META:LocalToWorld(local_pos, position, rotation, out)
	position = position or self:GetPosition()
	rotation = rotation or self:GetRotation()
	out = rotation:VecMul(local_pos, out)
	out.x = out.x + position.x
	out.y = out.y + position.y
	out.z = out.z + position.z
	return out
end

function META:GeometryLocalToWorld(local_pos, position, rotation, out)
	return self.Shape:GeometryLocalToWorld(self, local_pos, position, rotation, out)
end

function META:WorldToLocal(world_pos, position, rotation, out)
	position = position or self:GetPosition()
	rotation = rotation or self:GetRotation()
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
