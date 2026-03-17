local convex_manifold = import("goluwa/physics/convex_manifold.lua")
local triangle_geometry = {}

function triangle_geometry.GetTriangleNormal(a, b, c)
	return (b - a):GetCross(c - a):GetNormalized()
end

function triangle_geometry.GetTriangleCenter(a, b, c)
	return (a + b + c) / 3
end

function triangle_geometry.GetTriangleEdges(a, b, c, out)
	out = out or {}
	out[1] = b - a
	out[2] = c - b
	out[3] = a - c

	for i = 4, #out do
		out[i] = nil
	end

	return out
end

function triangle_geometry.ClosestPointOnTriangle(point, a, b, c)
	local ab = b - a
	local ac = c - a
	local ap = point - a
	local d1 = ab:Dot(ap)
	local d2 = ac:Dot(ap)

	if d1 <= 0 and d2 <= 0 then return a end

	local bp = point - b
	local d3 = ab:Dot(bp)
	local d4 = ac:Dot(bp)

	if d3 >= 0 and d4 <= d3 then return b end

	local vc = d1 * d4 - d3 * d2

	if vc <= 0 and d1 >= 0 and d3 <= 0 then
		local v = d1 / (d1 - d3)
		return a + ab * v
	end

	local cp = point - c
	local d5 = ab:Dot(cp)
	local d6 = ac:Dot(cp)

	if d6 >= 0 and d5 <= d6 then return c end

	local vb = d5 * d2 - d1 * d6

	if vb <= 0 and d2 >= 0 and d6 <= 0 then
		local w = d2 / (d2 - d6)
		return a + ac * w
	end

	local va = d3 * d6 - d5 * d4

	if va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0 then
		return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	end

	local denom = 1 / (va + vb + vc)
	local v = vb * denom
	local w = vc * denom
	return a + ab * v + ac * w
end

function triangle_geometry.PointInTriangle(point, a, b, c, normal, epsilon)
	epsilon = epsilon or 0.00001
	local edge0 = b - a
	local edge1 = c - b
	local edge2 = a - c
	local c0 = edge0:GetCross(point - a)
	local c1 = edge1:GetCross(point - b)
	local c2 = edge2:GetCross(point - c)
	return c0:Dot(normal) >= -epsilon and
		c1:Dot(normal) >= -epsilon and
		c2:Dot(normal) >= -epsilon
end

local function consider_segment_triangle_closest_points(segment_point, triangle_point, best)
	local distance = (segment_point - triangle_point):GetLength()

	if distance < best.distance then
		best.distance = distance
		best.segment = segment_point
		best.triangle = triangle_point
	end
end

function triangle_geometry.ClosestPointsOnSegmentTriangle(start_point, end_point, v0, v1, v2, options)
	options = options or {}
	local epsilon = options.epsilon or 0.00001
	local triangle_normal = triangle_geometry.GetTriangleNormal(v0, v1, v2)

	if triangle_normal:GetLength() > epsilon then
		local segment_delta = end_point - start_point
		local denominator = triangle_normal:Dot(segment_delta)

		if math.abs(denominator) > epsilon then
			local t = triangle_normal:Dot(v0 - start_point) / denominator

			if t >= 0 and t <= 1 then
				local point = start_point + segment_delta * t

				if triangle_geometry.PointInTriangle(point, v0, v1, v2, triangle_normal, epsilon) then
					return point, point, 0, triangle_normal
				end
			end
		end
	end

	local best = {
		segment = nil,
		triangle = nil,
		distance = math.huge,
	}
	consider_segment_triangle_closest_points(
		start_point,
		triangle_geometry.ClosestPointOnTriangle(start_point, v0, v1, v2),
		best
	)
	consider_segment_triangle_closest_points(end_point, triangle_geometry.ClosestPointOnTriangle(end_point, v0, v1, v2), best)
	local edge_segment, edge_triangle = convex_manifold.ClosestPointsOnSegments(start_point, end_point, v0, v1)
	consider_segment_triangle_closest_points(edge_segment, edge_triangle, best)
	edge_segment, edge_triangle = convex_manifold.ClosestPointsOnSegments(start_point, end_point, v1, v2)
	consider_segment_triangle_closest_points(edge_segment, edge_triangle, best)
	edge_segment, edge_triangle = convex_manifold.ClosestPointsOnSegments(start_point, end_point, v2, v0)
	consider_segment_triangle_closest_points(edge_segment, edge_triangle, best)

	if not (best.segment and best.triangle) then return nil end

	if triangle_normal:GetLength() <= epsilon then
		local delta = best.segment - best.triangle
		triangle_normal = delta:GetLength() > epsilon and
			(
				delta / delta:GetLength()
			)
			or
			options.fallback_normal
	end

	return best.segment, best.triangle, best.distance, triangle_normal
end

function triangle_geometry.GetTriangleArea(a, b, c)
	return (b - a):GetCross(c - a):GetLength() * 0.5
end

function triangle_geometry.GetPolygonArea(points)
	if not (points and points[1] and points[2] and points[3]) then return 0 end

	local origin = points[1]
	local area = 0

	for i = 2, #points - 1 do
		area = area + triangle_geometry.GetTriangleArea(origin, points[i], points[i + 1])
	end

	return area
end

return triangle_geometry