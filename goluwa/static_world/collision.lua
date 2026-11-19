local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local AABB = import("goluwa/structs/aabb.lua")
local brush_hull = import("goluwa/physics/brush_hull.lua")
local units = import("goluwa/static_world/units.lua")
local collision = {}
local BRUSH_POINT_EPSILON = 0.01
local source_pos_to_engine = units.PositionToEngine
local function build_brush_hull(planes)
	if not (planes and planes[1] and planes[4]) then return nil end

	return brush_hull.BuildHullFromPlanes(planes, BRUSH_POINT_EPSILON)
end

local function build_primitive_from_hull(hull, brush_planes)
	if
		not (
			hull and
			hull.bounds_min and
			hull.bounds_max and
			brush_planes and
			brush_planes[1]
		)
	then
		return nil
	end

	return {
		brush_planes = brush_planes,
		brush_hull = hull,
		aabb = AABB(
			hull.bounds_min.x,
			hull.bounds_min.y,
			hull.bounds_min.z,
			hull.bounds_max.x,
			hull.bounds_max.y,
			hull.bounds_max.z
		),
	}
end

local function build_displacement_polygon(points, dims)
	local poly = Polygon3D.New()
	local vertices = poly.Vertices

	for i = 1, dims * dims do
		vertices[i] = {pos = points[i]}
	end

	local indices = {}
	local count = 0

	for x = 1, dims - 1 do
		for y = 1, dims - 1 do
			local a = y * dims + x
			local b = (y - 1) * dims + x
			local c = a + 1
			local d = b + 1
			indices[count + 1], indices[count + 2], indices[count + 3] = a - 1, b - 1, c - 1
			indices[count + 4], indices[count + 5], indices[count + 6] = c - 1, b - 1, d - 1
			count = count + 6
		end
	end

	poly.indices = indices
	poly:BuildBoundingBox()
	return {Polygon3D = poly}
end

local function build_displacement_collision_shape(positions, dims)
	local points = {}

	for i = 1, dims * dims do
		points[i] = source_pos_to_engine(positions[i])
	end

	return build_displacement_polygon(points, dims)
end

local function build_triangle_soup_shape(positions)
	local poly = Polygon3D.New()
	local vertices = poly.Vertices
	local indices = {}

	for i, position in ipairs(positions) do
		vertices[i] = {pos = source_pos_to_engine(position)}
		indices[i] = i - 1
	end

	poly.indices = indices
	poly:BuildBoundingBox()
	return {Polygon3D = poly}
end

collision.build_brush_hull = build_brush_hull
collision.build_primitive_from_hull = build_primitive_from_hull
collision.build_triangle_soup_shape = build_triangle_soup_shape
collision.build_displacement_collision_shape = build_displacement_collision_shape
collision.build_displacement_polygon = build_displacement_polygon
function collision.build_brush_primitive(brush_planes)
	return build_primitive_from_hull(build_brush_hull(brush_planes), brush_planes)
end

function collision.update_brush_primitive(primitive, brush_planes)
	local updated = build_primitive_from_hull(build_brush_hull(brush_planes), brush_planes)

	if not updated then return false end

	primitive.brush_planes = updated.brush_planes
	primitive.brush_hull = updated.brush_hull
	primitive.mesh_shape_brush_polygon = nil
	primitive.aabb = updated.aabb
	return true
end
return collision
