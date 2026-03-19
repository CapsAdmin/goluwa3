local convex_hull = import("goluwa/physics/convex_hull.lua")
local brush_hull = {}
local BRUSH_HULL_EPSILON = 0.0001

local function intersect_brush_planes(plane_a, plane_b, plane_c)
	local n1 = plane_a.normal
	local n2 = plane_b.normal
	local n3 = plane_c.normal
	local n2_cross_n3 = n2:GetCross(n3)
	local determinant = n1:Dot(n2_cross_n3)

	if math.abs(determinant) <= 0.000001 then return nil end

	return (
			n2_cross_n3 * plane_a.dist + n3:GetCross(n1) * plane_b.dist + n1:GetCross(n2) * plane_c.dist
		) / determinant
end

local function is_point_inside_brush(point, planes, epsilon)
	epsilon = epsilon or BRUSH_HULL_EPSILON

	for _, plane in ipairs(planes or {}) do
		if point:Dot(plane.normal) - plane.dist > epsilon then return false end
	end

	return true
end

function brush_hull.BuildHullFromPlanes(planes, epsilon)
	if not (planes and planes[1] and planes[4]) then return nil end

	epsilon = epsilon or BRUSH_HULL_EPSILON
	local points = {}
	local seen = {}

	for i = 1, #planes - 2 do
		for j = i + 1, #planes - 1 do
			for k = j + 1, #planes do
				local point = intersect_brush_planes(planes[i], planes[j], planes[k])

				if point and is_point_inside_brush(point, planes, epsilon) then
					local key = string.format("%.4f:%.4f:%.4f", point.x, point.y, point.z)

					if not seen[key] then
						seen[key] = true
						points[#points + 1] = point
					end
				end
			end
		end
	end

	if #points < 4 then return nil end

	return convex_hull.Normalize(points, epsilon)
end

return brush_hull