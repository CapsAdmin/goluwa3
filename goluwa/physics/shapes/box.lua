local prototype = import("goluwa/prototype.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BaseShape = import("goluwa/physics/shapes/base.lua")
local META = prototype.CreateTemplate("physics_shape_box")
META.Base = BaseShape
META:GetSet("Size", Vec3(1, 1, 1))
local BOX_FACE_NORMALS = {
	Vec3(1, 0, 0),
	Vec3(-1, 0, 0),
	Vec3(0, 1, 0),
	Vec3(0, -1, 0),
	Vec3(0, 0, 1),
	Vec3(0, 0, -1),
}
local BOX_FACE_INDICES = {
	{2, 3, 7, 6},
	{1, 5, 8, 4},
	{4, 8, 7, 3},
	{1, 2, 6, 5},
	{5, 6, 7, 8},
	{1, 4, 3, 2},
}
local BOX_EDGE_PAIRS = {
	{1, 2},
	{2, 3},
	{3, 4},
	{4, 1},
	{5, 6},
	{6, 7},
	{7, 8},
	{8, 5},
	{1, 5},
	{2, 6},
	{3, 7},
	{4, 8},
}

function META.New(size)
	local shape = META:CreateObject()
	shape:SetSize(size or Vec3(1, 1, 1))
	return shape
end

function META:GetTypeName()
	return "box"
end

function META:OnBodyGeometryChanged(body)
	BaseShape.OnBodyGeometryChanged(self, body)
	self.Polyhedron = nil
end

function META:GetExtents()
	return self:GetSize() * 0.5
end

function META:GetHalfExtents()
	return self:GetExtents()
end

function META:GetMassProperties(body)
	local size = self:GetSize()
	local mass = body.Mass or 0

	if body.Static then
		mass = 0
	elseif body.AutomaticMass then
		mass = size.x * size.y * size.z * body.Density
	end

	if mass <= 0 then return 0, Vec3(0, 0, 0) end

	local sx, sy, sz = size.x, size.y, size.z
	local ix = (1 / 12) * mass * (sy * sy + sz * sz)
	local iy = (1 / 12) * mass * (sx * sx + sz * sz)
	local iz = (1 / 12) * mass * (sx * sx + sy * sy)
	return mass,
	Vec3(ix > 0 and 1 / ix or 0, iy > 0 and 1 / iy or 0, iz > 0 and 1 / iz or 0)
end

function META:GetAxes(body)
	local rotation = body:GetRotation()
	return {
		rotation:VecMul(Vec3(1, 0, 0)):GetNormalized(),
		rotation:VecMul(Vec3(0, 1, 0)):GetNormalized(),
		rotation:VecMul(Vec3(0, 0, 1)):GetNormalized(),
	}
end

function META:GetLocalVertices()
	local extents = self:GetExtents()
	local ex = extents.x
	local ey = extents.y
	local ez = extents.z
	return {
		Vec3(-ex, -ey, -ez),
		Vec3(ex, -ey, -ez),
		Vec3(ex, ey, -ez),
		Vec3(-ex, ey, -ez),
		Vec3(-ex, -ey, ez),
		Vec3(ex, -ey, ez),
		Vec3(ex, ey, ez),
		Vec3(-ex, ey, ez),
	}
end

function META:GetBroadphaseAABB(body, position, rotation)
	position = position or body:GetPosition()
	rotation = rotation or body:GetRotation()
	local bounds = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)

	for _, corner in ipairs(self:GetLocalVertices()) do
		bounds:ExpandVec3(position + rotation:VecMul(corner))
	end

	return bounds
end

function META:BuildCollisionLocalPoints()
	local extents = self:GetExtents()
	local ex = extents.x
	local ey = extents.y
	local ez = extents.z
	return {
		Vec3(-ex, -ey, -ez),
		Vec3(ex, -ey, -ez),
		Vec3(ex, ey, -ez),
		Vec3(-ex, ey, -ez),
		Vec3(-ex, -ey, ez),
		Vec3(ex, -ey, ez),
		Vec3(ex, ey, ez),
		Vec3(-ex, ey, ez),
		Vec3(0, -ey, 0),
		Vec3(0, ey, 0),
		Vec3(ex, 0, 0),
		Vec3(-ex, 0, 0),
		Vec3(0, 0, ez),
		Vec3(0, 0, -ez),
	}
end

function META:BuildSupportLocalPoints()
	local extents = self:GetExtents()
	local ex = extents.x
	local ey = extents.y
	local ez = extents.z
	return {
		Vec3(-ex, -ey, -ez),
		Vec3(ex, -ey, -ez),
		Vec3(ex, -ey, ez),
		Vec3(-ex, -ey, ez),
		Vec3(-ex * 0.5, -ey, -ez),
		Vec3(ex * 0.5, -ey, -ez),
		Vec3(ex * 0.5, -ey, ez),
		Vec3(-ex * 0.5, -ey, ez),
		Vec3(-ex, -ey, 0),
		Vec3(ex, -ey, 0),
		Vec3(0, -ey, -ez),
		Vec3(0, -ey, ez),
		Vec3(0, -ey, 0),
	}
end

function META:GetPolyhedron()
	if self.Polyhedron then return self.Polyhedron end

	local faces = {}

	for i, indices in ipairs(BOX_FACE_INDICES) do
		faces[i] = {
			indices = indices,
			normal = BOX_FACE_NORMALS[i],
		}
	end

	self.Polyhedron = {
		vertices = self:GetLocalVertices(),
		faces = faces,
		edges = BOX_EDGE_PAIRS,
	}
	return self.Polyhedron
end

function META:TraceDownAgainstBody(body, origin, max_distance)
	local physics = import("goluwa/physics/shared.lua")
	local distance_limit = max_distance or math.huge
	local movement_world = physics.Up * -distance_limit

	if movement_world:GetLength() <= 0.00001 then return nil end

	local start_local = body:WorldToLocal(origin)
	local end_local = body:WorldToLocal(origin + movement_world)
	local movement_local = end_local - start_local
	local extents = self:GetExtents()
	local t_enter = 0
	local t_exit = 1
	local hit_normal_local = nil
	local axis_data = {
		{"x", Vec3(-1, 0, 0), Vec3(1, 0, 0)},
		{"y", Vec3(0, -1, 0), Vec3(0, 1, 0)},
		{"z", Vec3(0, 0, -1), Vec3(0, 0, 1)},
	}

	for _, axis in ipairs(axis_data) do
		local name = axis[1]
		local s = start_local[name]
		local d = movement_local[name]
		local min_value = -extents[name]
		local max_value = extents[name]

		if math.abs(d) <= 0.00001 then
			if s < min_value or s > max_value then return nil end
		else
			local enter_t
			local exit_t
			local enter_normal

			if d > 0 then
				enter_t = (min_value - s) / d
				exit_t = (max_value - s) / d
				enter_normal = axis[2]
			else
				enter_t = (max_value - s) / d
				exit_t = (min_value - s) / d
				enter_normal = axis[3]
			end

			if enter_t > t_enter then
				t_enter = enter_t
				hit_normal_local = enter_normal
			end

			if exit_t < t_exit then t_exit = exit_t end

			if t_enter > t_exit then return nil end
		end
	end

	if not hit_normal_local or t_enter < 0 or t_enter > 1 then return nil end

	local position = origin + movement_world * t_enter
	local normal = body:GetRotation():VecMul(hit_normal_local):GetNormalized()

	if normal.y < 0 then return nil end

	return {
		entity = body.Owner,
		distance = distance_limit * t_enter,
		position = position,
		normal = normal,
		rigid_body = body,
	}
end

return META:Register()