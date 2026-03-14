local prototype = import("goluwa/prototype.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local AABB = import("goluwa/structs/aabb.lua")
local BaseShape = import("goluwa/physics/shapes/base.lua")
local ConvexShape = import("goluwa/physics/shapes/convex.lua")
local META = prototype.CreateTemplate("physics_shape_compound")
META.Base = BaseShape

local function identity_quat()
	return Quat(0, 0, 0, 1)
end

local function zero_vec3()
	return Vec3(0, 0, 0)
end

local function copy_child_rotation(rotation)
	if rotation and rotation.Copy then return rotation:Copy() end

	return identity_quat()
end

local function copy_child_position(position)
	if position and position.Copy then return position:Copy() end

	return zero_vec3()
end

local function get_child_shape(child)
	local shape = child.Shape or child.shape

	if not shape and child.ConvexHull then
		shape = ConvexShape.New(child.ConvexHull)
	end

	return shape
end

local function get_child_world_position(parent, child, position, rotation)
	position = position or parent:GetPosition()
	rotation = rotation or parent:GetRotation()
	return position + rotation:VecMul(child.Position)
end

local function get_child_world_rotation(parent, child, rotation)
	rotation = rotation or parent:GetRotation()
	return (rotation * child.Rotation):GetNormalized()
end

local ProxyMT = {}

function ProxyMT:__tostring()
	return tostring(self.Parent)
end

function ProxyMT:__index(key)
	if key == "Position" then
		return get_child_world_position(self.Parent, self.Child)
	end

	if key == "PreviousPosition" then
		return get_child_world_position(
			self.Parent,
			self.Child,
			self.Parent:GetPreviousPosition(),
			self.Parent:GetPreviousRotation()
		)
	end

	if key == "Rotation" then
		return get_child_world_rotation(self.Parent, self.Child)
	end

	if key == "PreviousRotation" then
		return get_child_world_rotation(self.Parent, self.Child, self.Parent:GetPreviousRotation())
	end

	if key == "InverseMass" or key == "InverseInertia" or key == "Owner" then
		return self.Parent[key]
	end

	local methods = rawget(ProxyMT, "Methods")

	if methods and methods[key] then return methods[key] end

	return self.Parent[key]
end

function ProxyMT:__newindex(key, value)
	if key == "Position" then
		local current = get_child_world_position(self.Parent, self.Child)
		self.Parent.Position = self.Parent.Position + (value - current)
		return
	end

	if key == "PreviousPosition" then
		local current = get_child_world_position(
			self.Parent,
			self.Child,
			self.Parent:GetPreviousPosition(),
			self.Parent:GetPreviousRotation()
		)
		self.Parent.PreviousPosition = self.Parent.PreviousPosition + (value - current)
		return
	end

	if key == "Rotation" then
		self.Parent.Rotation = (value * self.Child.Rotation:GetConjugated()):GetNormalized()
		return
	end

	if key == "PreviousRotation" then
		self.Parent.PreviousRotation = (value * self.Child.Rotation:GetConjugated()):GetNormalized()
		return
	end

	self.Parent[key] = value
end

ProxyMT.Methods = {
	GetBody = function(self)
		return self.Parent
	end,
	GetPhysicsShape = function(self)
		return self.Child.Shape
	end,
	GetShapeType = function(self)
		return self.Child.Shape:GetTypeName()
	end,
	GetResolvedConvexHull = function(self)
		local shape = self.Child.Shape
		return shape.GetResolvedHull and shape:GetResolvedHull(self) or nil
	end,
	GetPosition = function(self)
		return get_child_world_position(self.Parent, self.Child)
	end,
	GetPreviousPosition = function(self)
		return get_child_world_position(
			self.Parent,
			self.Child,
			self.Parent:GetPreviousPosition(),
			self.Parent:GetPreviousRotation()
		)
	end,
	GetRotation = function(self)
		return get_child_world_rotation(self.Parent, self.Child)
	end,
	GetPreviousRotation = function(self)
		return get_child_world_rotation(self.Parent, self.Child, self.Parent:GetPreviousRotation())
	end,
	LocalToWorld = function(self, local_pos, position, rotation)
		position = position or self:GetPosition()
		rotation = rotation or self:GetRotation()
		return position + rotation:VecMul(local_pos)
	end,
	WorldToLocal = function(self, world_pos, position, rotation)
		position = position or self:GetPosition()
		rotation = rotation or self:GetRotation()
		return rotation:GetConjugated():VecMul(world_pos - position)
	end,
	GeometryLocalToWorld = function(self, local_pos, position, rotation)
		return self.Child.Shape:GeometryLocalToWorld(self, local_pos, position, rotation)
	end,
	GetBroadphaseAABB = function(self, position, rotation)
		return self.Child.Shape:GetBroadphaseAABB(self, position, rotation)
	end,
	GetCollisionLocalPoints = function(self)
		return self.Child.Shape:BuildCollisionLocalPoints(self)
	end,
	GetSupportLocalPoints = function(self)
		return self.Child.Shape:BuildSupportLocalPoints(self)
	end,
	GetHalfExtents = function(self)
		return self.Child.Shape:GetHalfExtents(self)
	end,
	ApplyCorrection = function(self, compliance, correction, pos, other_body, other_pos, dt)
		local other = other_body and other_body.Parent or other_body
		return self.Parent:ApplyCorrection(compliance, correction, pos, other, other_pos, dt)
	end,
	GetInverseMassAlong = function(self, normal, pos)
		return self.Parent:GetInverseMassAlong(normal, pos)
	end,
	GetVelocity = function(self)
		return self.Parent:GetVelocity()
	end,
	SetVelocity = function(self, vec)
		return self.Parent:SetVelocity(vec)
	end,
	GetAngularVelocity = function(self)
		return self.Parent:GetAngularVelocity()
	end,
	SetAngularVelocity = function(self, vec)
		return self.Parent:SetAngularVelocity(vec)
	end,
	SetGrounded = function(self, grounded)
		return self.Parent:SetGrounded(grounded)
	end,
	GetGrounded = function(self)
		return self.Parent:GetGrounded()
	end,
	SetGroundNormal = function(self, normal)
		return self.Parent:SetGroundNormal(normal)
	end,
	GetGroundNormal = function(self)
		return self.Parent:GetGroundNormal()
	end,
	IsStatic = function(self)
		return self.Parent:IsStatic()
	end,
	IsKinematic = function(self)
		return self.Parent:IsKinematic()
	end,
	IsDynamic = function(self)
		return self.Parent:IsDynamic()
	end,
	HasSolverMass = function(self)
		return self.Parent:HasSolverMass()
	end,
	IsSolverImmovable = function(self)
		return self.Parent:IsSolverImmovable()
	end,
	Wake = function(self)
		return self.Parent:Wake()
	end,
	Sleep = function(self)
		return self.Parent:Sleep()
	end,
}

function META.New(children)
	local shape = META:CreateObject()
	shape.Children = {}
	shape.ProxyBodies = setmetatable({}, {__mode = "k"})

	if children and children.children then children = children.children end

	for _, child in ipairs(children or {}) do
		shape:AddChild(
			child.Shape or child.shape,
			child.Position or child.position,
			child.Rotation or child.rotation,
			child
		)
	end

	return shape
end

function META:GetTypeName()
	return "compound"
end

function META:OnBodyGeometryChanged(body)
	BaseShape.OnBodyGeometryChanged(self, body)
	self.LocalBounds = nil
	self.ProxyBodies = setmetatable({}, {__mode = "k"})

	for _, child in ipairs(self.Children or {}) do
		if child.Shape and child.Shape.OnBodyGeometryChanged then
			child.Shape:OnBodyGeometryChanged(body)
		end
	end
end

function META:GetChildren()
	self.Children = self.Children or {}
	return self.Children
end

function META:AddChild(shape, local_position, local_rotation, data)
	self.Children = self.Children or {}
	local child = {}

	if data then for key, value in pairs(data) do
		child[key] = value
	end end

	child.Shape = shape or get_child_shape(child)
	assert(child.Shape, "compound child requires Shape or ConvexHull")
	child.Position = copy_child_position(local_position or child.Position or child.position)
	child.Rotation = copy_child_rotation(local_rotation or child.Rotation or child.rotation)
	self.Children[#self.Children + 1] = child
	self.LocalBounds = nil
	self.ProxyBodies = setmetatable({}, {__mode = "k"})
	return child
end

function META:GetChildProxyBodies(body)
	self.ProxyBodies = self.ProxyBodies or setmetatable({}, {__mode = "k"})
	local cached = self.ProxyBodies[body]

	if cached then return cached end

	cached = {}

	for index, child in ipairs(self:GetChildren()) do
		cached[index] = setmetatable({Parent = body, Child = child, ChildIndex = index}, ProxyMT)
	end

	self.ProxyBodies[body] = cached
	return cached
end

function META:BuildLocalBounds(body)
	local min_bounds = Vec3(math.huge, math.huge, math.huge)
	local max_bounds = Vec3(-math.huge, -math.huge, -math.huge)
	local has_points = false

	for _, child_body in ipairs(self:GetChildProxyBodies(body or self.Body)) do
		for _, point in ipairs(child_body:GetCollisionLocalPoints() or {}) do
			local transformed = child_body.Child.Position + child_body.Child.Rotation:VecMul(point)
			min_bounds.x = math.min(min_bounds.x, transformed.x)
			min_bounds.y = math.min(min_bounds.y, transformed.y)
			min_bounds.z = math.min(min_bounds.z, transformed.z)
			max_bounds.x = math.max(max_bounds.x, transformed.x)
			max_bounds.y = math.max(max_bounds.y, transformed.y)
			max_bounds.z = math.max(max_bounds.z, transformed.z)
			has_points = true
		end
	end

	if not has_points then
		min_bounds = Vec3(-0.5, -0.5, -0.5)
		max_bounds = Vec3(0.5, 0.5, 0.5)
	end

	self.LocalBounds = {min = min_bounds, max = max_bounds}
	return self.LocalBounds
end

function META:GetHalfExtents(body)
	local bounds = self.LocalBounds or self:BuildLocalBounds(body)
	return (bounds.max - bounds.min) * 0.5
end

function META:GetMassProperties(body)
	local mass = body.Mass or 0

	if body.IsDynamic and not body:IsDynamic() then
		mass = 0
	elseif body.AutomaticMass then
		mass = 0

		for _, child_body in ipairs(self:GetChildProxyBodies(body)) do
			local child_mass = select(1, child_body:GetPhysicsShape():GetMassProperties(child_body)) or 0
			mass = mass + child_mass
		end
	end

	if mass <= 0 then return 0, Vec3(0, 0, 0) end

	local bounds = self.LocalBounds or self:BuildLocalBounds(body)
	local size = bounds.max - bounds.min
	local sx, sy, sz = size.x, size.y, size.z
	local ix = (1 / 12) * mass * (sy * sy + sz * sz)
	local iy = (1 / 12) * mass * (sx * sx + sz * sz)
	local iz = (1 / 12) * mass * (sx * sx + sy * sy)
	return mass,
	Vec3(ix > 0 and 1 / ix or 0, iy > 0 and 1 / iy or 0, iz > 0 and 1 / iz or 0)
end

function META:BuildCollisionLocalPoints(body)
	local points = {}

	for _, child_body in ipairs(self:GetChildProxyBodies(body or self.Body)) do
		for _, point in ipairs(child_body:GetCollisionLocalPoints() or {}) do
			points[#points + 1] = child_body.Child.Position + child_body.Child.Rotation:VecMul(point)
		end
	end

	return points
end

function META:BuildSupportLocalPoints(body)
	local points = {}

	for _, child_body in ipairs(self:GetChildProxyBodies(body or self.Body)) do
		for _, point in ipairs(child_body:GetSupportLocalPoints() or {}) do
			points[#points + 1] = child_body.Child.Position + child_body.Child.Rotation:VecMul(point)
		end
	end

	return points
end

function META:GetBroadphaseAABB(body, position, rotation)
	local bounds = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)
	local has_bounds = false

	for _, child in ipairs(self:GetChildren()) do
		local child_position = get_child_world_position(body, child, position, rotation)
		local child_rotation = get_child_world_rotation(body, child, rotation or body:GetRotation())
		local child_bounds = child.Shape:GetBroadphaseAABB(body, child_position, child_rotation)
		bounds.min_x = math.min(bounds.min_x, child_bounds.min_x)
		bounds.min_y = math.min(bounds.min_y, child_bounds.min_y)
		bounds.min_z = math.min(bounds.min_z, child_bounds.min_z)
		bounds.max_x = math.max(bounds.max_x, child_bounds.max_x)
		bounds.max_y = math.max(bounds.max_y, child_bounds.max_y)
		bounds.max_z = math.max(bounds.max_z, child_bounds.max_z)
		has_bounds = true
	end

	if has_bounds then return bounds end

	return BaseShape.GetBroadphaseAABB(self, body, position, rotation)
end

function META:TraceDownAgainstBody(body, origin, max_distance)
	local best_hit = nil

	for _, child_body in ipairs(self:GetChildProxyBodies(body)) do
		local shape = child_body:GetPhysicsShape()
		local hit = shape.TraceDownAgainstBody and
			shape:TraceDownAgainstBody(child_body, origin, max_distance)

		if hit and (not best_hit or hit.distance < best_hit.distance) then
			best_hit = hit
		end
	end

	return best_hit
end

return META:Register()