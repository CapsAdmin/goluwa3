local prototype = import("goluwa/prototype.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Matrix33 = import("goluwa/structs/matrix33.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BaseShape = import("goluwa/physics/shapes/base.lua")
local triangle_mesh = import("goluwa/physics/triangle_mesh.lua")
local META = prototype.CreateTemplate("physics_shape_mesh")
META.Base = BaseShape

local function append_polygon(polygons, seen, polygon)
	if not (polygon and polygon.Vertices) then return end

	if seen[polygon] then return end

	seen[polygon] = true
	polygons[#polygons + 1] = polygon
end

local function collect_polygons_from_source(polygons, seen, source)
	if not source then return end

	if source.Vertices then
		append_polygon(polygons, seen, source)
		return
	end

	if source.polygon3d then
		append_polygon(polygons, seen, source.polygon3d)
		return
	end

	if source.Primitives then
		for _, primitive in ipairs(source.Primitives) do
			collect_polygons_from_source(polygons, seen, primitive)
		end

		return
	end

	if source[1] then
		for _, entry in ipairs(source) do
			collect_polygons_from_source(polygons, seen, entry)
		end
	end
end

local function bounds_from_points(points)
	if not (points and points[1]) then return nil end

	local bounds = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)

	for _, point in ipairs(points) do
		if point then bounds:ExpandVec3(point) end
	end

	return bounds
end

local function add_bounds(bounds, poly_bounds)
	if not poly_bounds then return bounds end

	if not bounds then
		return AABB(
			poly_bounds.min_x,
			poly_bounds.min_y,
			poly_bounds.min_z,
			poly_bounds.max_x,
			poly_bounds.max_y,
			poly_bounds.max_z
		)
	end

	bounds.min_x = math.min(bounds.min_x, poly_bounds.min_x)
	bounds.min_y = math.min(bounds.min_y, poly_bounds.min_y)
	bounds.min_z = math.min(bounds.min_z, poly_bounds.min_z)
	bounds.max_x = math.max(bounds.max_x, poly_bounds.max_x)
	bounds.max_y = math.max(bounds.max_y, poly_bounds.max_y)
	bounds.max_z = math.max(bounds.max_z, poly_bounds.max_z)
	return bounds
end

function META.New(source)
	local shape = META:CreateObject()

	if source and source.Source ~= nil then
		shape.Source = source.Source
	elseif source and source.Polygon3D ~= nil then
		shape.Source = source.Polygon3D
	elseif source and source.Primitive ~= nil then
		shape.Source = source.Primitive
	elseif source and source.Model ~= nil then
		shape.Source = source.Model
	elseif source and source.Polygons ~= nil then
		shape.Source = source.Polygons
	else
		shape.Source = source
	end

	return shape
end

function META:GetTypeName()
	return "mesh"
end

function META:OnBodyGeometryChanged(body)
	BaseShape.OnBodyGeometryChanged(self, body)
	self.ResolvedPolygons = nil
	self.LocalBounds = nil
	self.CollisionLocalPoints = nil
	self.SupportLocalPoints = nil
end

function META:GetMeshSource(body)
	if self.Source ~= nil then return self.Source end

	local owner = body and body.GetOwner and body:GetOwner() or body and body.Owner
	return owner and owner.model or nil
end

function META:GetMeshPolygons(body)
	if self.ResolvedPolygons then return self.ResolvedPolygons end

	local polygons = {}
	collect_polygons_from_source(polygons, {}, self:GetMeshSource(body))
	self.ResolvedPolygons = polygons
	return polygons
end

function META:GetLocalBounds(body)
	if self.LocalBounds then return self.LocalBounds end

	local bounds = nil

	for _, poly in ipairs(self:GetMeshPolygons(body)) do
		local poly_bounds = poly.GetAABB and poly:GetAABB() or poly.AABB

		if not poly_bounds then
			local points = triangle_mesh.GetPolygonLocalVertices(poly)
			poly_bounds = bounds_from_points(points)
		end

		bounds = add_bounds(bounds, poly_bounds)
	end

	self.LocalBounds = bounds or AABB(-0.5, -0.5, -0.5, 0.5, 0.5, 0.5)
	return self.LocalBounds
end

function META:GetHalfExtents(body)
	local bounds = self:GetLocalBounds(body)
	return Vec3(
		(bounds.max_x - bounds.min_x) * 0.5,
		(bounds.max_y - bounds.min_y) * 0.5,
		(bounds.max_z - bounds.min_z) * 0.5
	)
end

function META:GetMassProperties()
	return 0, Matrix33():SetZero()
end

function META:BuildCollisionLocalPoints(body)
	local points = {}

	for _, poly in ipairs(self:GetMeshPolygons(body)) do
		local vertices = triangle_mesh.GetPolygonLocalVertices(poly)

		for _, point in ipairs(vertices or {}) do
			if point then points[#points + 1] = point end
		end
	end

	if points[1] then return points end

	return BaseShape.BuildCollisionLocalPoints(self, body)
end

function META:BuildSupportLocalPoints(body)
	local points = self:BuildCollisionLocalPoints(body)

	if not points[1] then return BaseShape.BuildSupportLocalPoints(self, body) end

	local min_y = math.huge

	for _, point in ipairs(points) do
		min_y = math.min(min_y, point.y)
	end

	local support = {}
	local tolerance = 0.08

	for _, point in ipairs(points) do
		if math.abs(point.y - min_y) <= tolerance then
			support[#support + 1] = point
		end
	end

	if support[1] then return support end

	return BaseShape.BuildSupportLocalPoints(self, body)
end

function META:GetBroadphaseAABB(body, position, rotation)
	position = position or body:GetPosition()
	rotation = rotation or body:GetRotation()
	local bounds = self:GetLocalBounds(body)
	local min_x = bounds.min_x
	local min_y = bounds.min_y
	local min_z = bounds.min_z
	local max_x = bounds.max_x
	local max_y = bounds.max_y
	local max_z = bounds.max_z
	local corners = {
		Vec3(min_x, min_y, min_z),
		Vec3(max_x, min_y, min_z),
		Vec3(max_x, max_y, min_z),
		Vec3(min_x, max_y, min_z),
		Vec3(min_x, min_y, max_z),
		Vec3(max_x, min_y, max_z),
		Vec3(max_x, max_y, max_z),
		Vec3(min_x, max_y, max_z),
	}
	local world_bounds = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)

	for _, corner in ipairs(corners) do
		world_bounds:ExpandVec3(position + rotation:VecMul(corner))
	end

	return world_bounds
end

function META:ForEachOverlappingTriangle(body, local_bounds, callback, context)
	for _, poly in ipairs(self:GetMeshPolygons(body)) do
		triangle_mesh.ForEachOverlappingTriangle(poly, local_bounds, callback, context)
	end
end

return META:Register()