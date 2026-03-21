local prototype = import("goluwa/prototype.lua")
local AABB = import("goluwa/structs/aabb.lua")
local BVH = import("goluwa/physics/bvh.lua")
local brush_hull = import("goluwa/physics/brush_hull.lua")
local Matrix33 = import("goluwa/structs/matrix33.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BaseShape = import("goluwa/physics/shapes/base.lua")
local triangle_mesh = import("goluwa/physics/triangle_mesh.lua")
local META = prototype.CreateTemplate("physics_shape_mesh")
META.Base = BaseShape
local MESH_POLYGON_BVH_THRESHOLD = 12
local MESH_POLYGON_BVH_LEAF_COUNT = 6

local MESH_BOUNDS_CORNERS = {
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
}

local function create_synthetic_primitive(polygon)
	return {polygon3d = polygon}
end

local function bounds_from_points(points)
	if not (points and points[1]) then return nil end

	local bounds = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)

	for _, point in ipairs(points) do
		if point then bounds:ExpandVec3(point) end
	end

	return bounds
end

local function get_polygon_local_bounds(poly)
	if not (poly and poly.Vertices) then return nil end

	local vertices = poly.Vertices
	local vertex_count = #vertices

	if
		poly.mesh_shape_local_bounds and
		poly.mesh_shape_local_bounds_source == vertices and
		poly.mesh_shape_local_bounds_vertex_count == vertex_count
	then
		return poly.mesh_shape_local_bounds
	end

	local bounds = poly.GetAABB and poly:GetAABB() or poly.AABB

	if not bounds then
		local points = triangle_mesh.GetPolygonLocalVertices(poly)
		bounds = bounds_from_points(points)
	end

	poly.mesh_shape_local_bounds = bounds
	poly.mesh_shape_local_bounds_source = vertices
	poly.mesh_shape_local_bounds_vertex_count = vertex_count
	return bounds
end

local function build_brush_polygon(primitive)
	if not (primitive and primitive.brush_planes) then return nil end

	if primitive.mesh_shape_brush_polygon then return primitive.mesh_shape_brush_polygon end

	local hull = primitive.brush_hull or brush_hull.BuildHullFromPlanes(primitive.brush_planes)

	if
		not (
			hull and
			hull.vertices and
			hull.vertices[1] and
			hull.indices and
			hull.indices[1]
		)
	then
		return nil
	end

	primitive.brush_hull = hull
	local indices = {}

	for i = 1, #hull.indices do
		indices[i] = hull.indices[i] - 1
	end

	primitive.mesh_shape_brush_polygon = {
		Vertices = hull.vertices,
		indices = indices,
		AABB = AABB(
			hull.bounds_min.x,
			hull.bounds_min.y,
			hull.bounds_min.z,
			hull.bounds_max.x,
			hull.bounds_max.y,
			hull.bounds_max.z
		),
	}
	return primitive.mesh_shape_brush_polygon
end

local function append_polygon_entry(entries, seen, polygon, primitive, primitive_index, model)
	if not (polygon and polygon.Vertices) then return end

	if seen[polygon] then return end

	seen[polygon] = true
	local bounds = get_polygon_local_bounds(polygon)
	entries[#entries + 1] = {
		polygon = polygon,
		bounds = bounds,
		centroid_x = bounds and (bounds.min_x + bounds.max_x) * 0.5 or 0,
		centroid_y = bounds and (bounds.min_y + bounds.max_y) * 0.5 or 0,
		centroid_z = bounds and (bounds.min_z + bounds.max_z) * 0.5 or 0,
		primitive = primitive or create_synthetic_primitive(polygon),
		primitive_index = primitive_index,
		model = model,
	}
end

local function get_polygon_entry_bounds(entry)
	return entry and entry.bounds or nil
end

local function get_polygon_entry_centroid(entry)
	if not entry then return 0, 0, 0 end

	return entry.centroid_x or 0, entry.centroid_y or 0, entry.centroid_z or 0
end

local function collect_polygon_entries_from_source(entries, seen, source, model, primitive, primitive_index)
	if not source then return end

	if source.Vertices then
		append_polygon_entry(entries, seen, source, primitive, primitive_index, model)
		return
	end

	if source.polygon3d then
		append_polygon_entry(entries, seen, source.polygon3d, source, primitive_index, model)
		return
	end

	if source.brush_planes then
		local polygon = build_brush_polygon(source)

		if polygon then append_polygon_entry(entries, seen, polygon, source, primitive_index, model) end

		return
	end

	if source.Primitives then
		for index, model_primitive in ipairs(source.Primitives) do
			collect_polygon_entries_from_source(entries, seen, model_primitive, source, model_primitive, index)
		end

		return
	end

	if source[1] then
		for _, entry in ipairs(source) do
			collect_polygon_entries_from_source(entries, seen, entry, model, primitive, primitive_index)
		end
	end
end

local function create_ray(origin, direction, max_distance)
	local ray = {
		origin = origin,
		direction = direction:GetNormalized(),
		max_distance = max_distance or math.huge,
	}
	ray.inv_direction = Vec3(
		ray.direction.x ~= 0 and 1 / ray.direction.x or math.huge,
		ray.direction.y ~= 0 and 1 / ray.direction.y or math.huge,
		ray.direction.z ~= 0 and 1 / ray.direction.z or math.huge
	)
	return ray
end

local function ray_triangle_intersection(ray, v0, v1, v2)
	local epsilon = 0.0000001
	local edge1 = v1 - v0
	local edge2 = v2 - v0
	local h = ray.direction:GetCross(edge2)
	local a = edge1:Dot(h)

	if a > -epsilon and a < epsilon then return false end

	local f = 1.0 / a
	local s = ray.origin - v0
	local u = f * s:Dot(h)

	if u < 0.0 or u > 1.0 then return false end

	local q = s:GetCross(edge1)
	local v = f * ray.direction:Dot(q)

	if v < 0.0 or u + v > 1.0 then return false end

	local t = f * edge2:Dot(q)

	if t > epsilon and t <= ray.max_distance then return true, t end

	return false
end

local function build_triangle_hit(collider, entry, ray_origin, ray_direction, distance, trace_radius, triangle)
	local face_normal_local = (triangle.v1 - triangle.v0):Cross(triangle.v2 - triangle.v0):GetNormalized()

	if face_normal_local:GetLength() <= 0.00001 then return nil end

	local face_normal = collider:GetRotation():VecMul(face_normal_local):GetNormalized()

	if face_normal:Dot(ray_direction) > 0 then face_normal = face_normal * -1 end

	local position = ray_origin + ray_direction * distance
	local radius = math.max(trace_radius or 0, 0)

	if radius > 0 then position = position - face_normal * radius end

	return {
		entity = collider:GetOwner(),
		distance = distance,
		position = position,
		normal = face_normal,
		face_normal = face_normal,
		rigid_body = collider.GetBody and collider:GetBody() or collider,
		collider = collider,
		primitive = entry.primitive,
		primitive_index = entry.primitive_index,
		triangle_index = triangle.triangle_index,
		model = entry.model,
		poly = entry.polygon,
	}
end

local function test_triangle_hit(context, triangle)
	local hit, distance = ray_triangle_intersection(context.local_ray, triangle.v0, triangle.v1, triangle.v2)

	if not hit or distance > context.best_distance then return end

	local candidate = build_triangle_hit(
		context.collider,
		context.entry,
		context.ray_origin,
		context.ray_direction,
		distance,
		context.trace_radius,
		triangle
	)

	if candidate then
		context.best_hit = candidate
		context.best_distance = candidate.distance
	end
end

local function visit_triangle_leaf(node, context, best_hit, best_distance)
	for i = node.first, node.last do
		local triangle = context.acceleration.triangles[i]
		local hit, distance = ray_triangle_intersection(context.local_ray, triangle.v0, triangle.v1, triangle.v2)

		if hit and distance < best_distance then
			local candidate = build_triangle_hit(
				context.collider,
				context.entry,
				context.ray_origin,
				context.ray_direction,
				distance,
				context.trace_radius,
				triangle
			)

			if candidate then
				best_hit = candidate
				best_distance = candidate.distance
			end
		end
	end

	return best_hit, best_distance
end

local function trace_polygon_entry(context, entry, best_hit, best_distance)
	local bounds = entry.bounds

	if bounds then
		local hit_bounds, tmin = BVH.RayAABBIntersection(context.local_ray, bounds)

		if not hit_bounds or tmin > best_distance then return best_hit, best_distance end
	end

	local acceleration, triangles, triangle_count = triangle_mesh.GetPolygonTriangleAcceleration(entry.polygon)

	if acceleration then
		local traversal_context = acceleration.traversal_context or {acceleration = acceleration, node_stack = {}, tmin_stack = {}}
		acceleration.traversal_context = traversal_context
		traversal_context.acceleration = acceleration
		traversal_context.local_ray = context.local_ray
		traversal_context.collider = context.collider
		traversal_context.entry = entry
		traversal_context.ray_origin = context.ray_origin
		traversal_context.ray_direction = context.ray_direction
		traversal_context.trace_radius = context.trace_radius
		return BVH.TraverseRay(
			context.local_ray,
			acceleration.root,
			visit_triangle_leaf,
			traversal_context,
			best_hit,
			best_distance
		)
	end

	if triangles and triangle_count > 0 then
		local leaf_context = {
			collider = context.collider,
			entry = entry,
			local_ray = context.local_ray,
			ray_origin = context.ray_origin,
			ray_direction = context.ray_direction,
			trace_radius = context.trace_radius,
			best_hit = best_hit,
			best_distance = best_distance,
		}

		for i = 1, triangle_count do
			test_triangle_hit(leaf_context, triangles[i])
		end

		return leaf_context.best_hit, leaf_context.best_distance
	end

	return best_hit, best_distance
end

local function visit_polygon_leaf(node, context, result)
	local entries = context.acceleration.entries
	local user_context = context.user_context
	local previous_entry = user_context and user_context.entry or nil

	for i = node.first, node.last do
		local entry = entries[i]

		if user_context then user_context.entry = entry end
		triangle_mesh.ForEachOverlappingTriangle(entry.polygon, context.local_bounds, context.callback, context.user_context)
	end

	if user_context then user_context.entry = previous_entry end

	return result
end

local function visit_ray_polygon_leaf(node, context, best_hit, best_distance)
	local entries = context.acceleration.entries

	for i = node.first, node.last do
		best_hit, best_distance = trace_polygon_entry(context, entries[i], best_hit, best_distance)
	end

	return best_hit, best_distance
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
	self.ResolvedPolygonEntries = nil
	self.ResolvedPolygonAcceleration = nil
	self.ResolvedPolygonAccelerationSource = nil
	self.ResolvedPolygonAccelerationCount = nil
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

function META:GetMeshPolygonEntries(body)
	if self.ResolvedPolygonEntries then return self.ResolvedPolygonEntries end

	local entries = {}
	collect_polygon_entries_from_source(entries, {}, self:GetMeshSource(body))
	self.ResolvedPolygonEntries = entries
	return entries
end

function META:GetMeshPolygonAcceleration(body)
	local entries = self:GetMeshPolygonEntries(body)
	local count = #entries

	if count < MESH_POLYGON_BVH_THRESHOLD then return nil, entries, count end

	if
		self.ResolvedPolygonAcceleration and
		self.ResolvedPolygonAccelerationSource == entries and
		self.ResolvedPolygonAccelerationCount == count
	then
		return self.ResolvedPolygonAcceleration, entries, count
	end

	local tree = BVH.Build(entries, get_polygon_entry_bounds, get_polygon_entry_centroid, MESH_POLYGON_BVH_LEAF_COUNT)

	if not tree then return nil, entries, count end

	tree.entries = tree.items
	tree.items = nil
	tree.traversal_context = tree.traversal_context or {
		acceleration = tree,
		node_stack = {},
		tmin_stack = {},
	}
	self.ResolvedPolygonAcceleration = tree
	self.ResolvedPolygonAccelerationSource = entries
	self.ResolvedPolygonAccelerationCount = count
	return tree, entries, count
end

function META:GetMeshPolygons(body)
	if self.ResolvedPolygons then return self.ResolvedPolygons end

	local polygons = {}

	for _, entry in ipairs(self:GetMeshPolygonEntries(body)) do
		polygons[#polygons + 1] = entry.polygon
	end

	self.ResolvedPolygons = polygons
	return polygons
end

function META:GetLocalBounds(body)
	if self.LocalBounds then return self.LocalBounds end

	local bounds = nil

	for _, entry in ipairs(self:GetMeshPolygonEntries(body)) do
		bounds = add_bounds(bounds, entry.bounds or get_polygon_local_bounds(entry.polygon))
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
	local corners = MESH_BOUNDS_CORNERS
	corners[1].x, corners[1].y, corners[1].z = min_x, min_y, min_z
	corners[2].x, corners[2].y, corners[2].z = max_x, min_y, min_z
	corners[3].x, corners[3].y, corners[3].z = max_x, max_y, min_z
	corners[4].x, corners[4].y, corners[4].z = min_x, max_y, min_z
	corners[5].x, corners[5].y, corners[5].z = min_x, min_y, max_z
	corners[6].x, corners[6].y, corners[6].z = max_x, min_y, max_z
	corners[7].x, corners[7].y, corners[7].z = max_x, max_y, max_z
	corners[8].x, corners[8].y, corners[8].z = min_x, max_y, max_z

	local world_min_x = math.huge
	local world_min_y = math.huge
	local world_min_z = math.huge
	local world_max_x = -math.huge
	local world_max_y = -math.huge
	local world_max_z = -math.huge

	for i = 1, 8 do
		local transformed = position + rotation:VecMul(corners[i])
		local x = transformed.x
		local y = transformed.y
		local z = transformed.z

		if x < world_min_x then world_min_x = x end
		if y < world_min_y then world_min_y = y end
		if z < world_min_z then world_min_z = z end
		if x > world_max_x then world_max_x = x end
		if y > world_max_y then world_max_y = y end
		if z > world_max_z then world_max_z = z end
	end

	return AABB(world_min_x, world_min_y, world_min_z, world_max_x, world_max_y, world_max_z)
end

function META:ForEachOverlappingTriangle(body, local_bounds, callback, context)
	local entries = self:GetMeshPolygonEntries(body)
	local acceleration = nil

	if local_bounds then acceleration = self:GetMeshPolygonAcceleration(body) end

	if acceleration and local_bounds then
		local traversal_context = acceleration.traversal_context
		traversal_context.acceleration = acceleration
		traversal_context.local_bounds = local_bounds
		traversal_context.callback = callback
		traversal_context.user_context = context
		BVH.TraverseAABB(local_bounds, acceleration.root, visit_polygon_leaf, traversal_context, nil)
		return
	end

	for i = 1, #entries do
		local entry = entries[i]
		local polygon_bounds = entry.bounds or get_polygon_local_bounds(entry.polygon)

		if not local_bounds or not polygon_bounds or polygon_bounds:IsBoxIntersecting(local_bounds) then
			local previous_entry = context and context.entry or nil

			if context then context.entry = entry end
			triangle_mesh.ForEachOverlappingTriangle(entry.polygon, local_bounds, callback, context)

			if context then context.entry = previous_entry end
		end
	end
end

function META:TraceAgainstBody(collider, origin, direction, max_distance, trace_radius)
	local ray_direction = direction and direction:GetNormalized() or Vec3(0, 0, 0)

	if ray_direction:GetLength() <= 0.00001 then return nil end

	local distance_limit = max_distance or math.huge
	local world_ray = create_ray(origin, ray_direction, distance_limit)
	local bounds = collider:GetBroadphaseAABB()

	if bounds and not BVH.RayAABBIntersection(world_ray, bounds) then return nil end

	local local_origin = collider:WorldToLocal(origin)
	local local_direction = collider:GetRotation():GetConjugated():VecMul(ray_direction):GetNormalized()
	local local_ray = create_ray(local_origin, local_direction, distance_limit)
	local best_hit = nil
	local best_distance = distance_limit
	local acceleration = self:GetMeshPolygonAcceleration(collider)

	if acceleration then
		local traversal_context = acceleration.traversal_context
		traversal_context.acceleration = acceleration
		traversal_context.local_ray = local_ray
		traversal_context.collider = collider
		traversal_context.ray_origin = origin
		traversal_context.ray_direction = ray_direction
		traversal_context.trace_radius = trace_radius
		best_hit, best_distance = BVH.TraverseRay(
			local_ray,
			acceleration.root,
			visit_ray_polygon_leaf,
			traversal_context,
			best_hit,
			best_distance
		)
		return best_hit
	end

	for _, entry in ipairs(self:GetMeshPolygonEntries(collider)) do
		best_hit, best_distance = trace_polygon_entry(
			{
				local_ray = local_ray,
				collider = collider,
				ray_origin = origin,
				ray_direction = ray_direction,
				trace_radius = trace_radius,
			},
			entry,
			best_hit,
			best_distance
		)
	end

	return best_hit
end

return META:Register()
