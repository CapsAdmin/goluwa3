local AABB = import("goluwa/structs/aabb.lua")
local brush_hull = import("goluwa/physics/brush_hull.lua")
local primitive_polygon_query = {}

local function build_brush_polygon(primitive)
	if not (primitive and primitive.brush_planes) then return nil end

	if primitive.world_brush_polygon then return primitive.world_brush_polygon end

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

	primitive.world_brush_polygon = {
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
	return primitive.world_brush_polygon
end

local function is_supported_primitive(primitive)
	return primitive and (primitive.polygon3d or primitive.brush_planes) or false
end

function primitive_polygon_query.GetPrimitivePolygon(primitive)
	if not is_supported_primitive(primitive) then return nil end

	if primitive.polygon3d then return primitive.polygon3d end

	return build_brush_polygon(primitive)
end

return primitive_polygon_query
