local convex_hull = import("goluwa/physics/convex_hull.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local brush_hull = {}
local BRUSH_HULL_EPSILON = 0.0001

-- the corners are where three planes meet inside all the others. plain numbers rather than
-- Vec3 keep the intersection in double precision
function brush_hull.BuildHullFromPlanes(planes, epsilon)
	if not (planes and planes[1] and planes[4]) then return nil end

	epsilon = epsilon or BRUSH_HULL_EPSILON
	local points = {}
	local count = #planes

	for i = 1, count - 2 do
		local n1 = planes[i].normal
		local x1, y1, z1, d1 = n1.x, n1.y, n1.z, planes[i].dist

		for j = i + 1, count - 1 do
			local n2 = planes[j].normal
			local x2, y2, z2, d2 = n2.x, n2.y, n2.z, planes[j].dist

			for k = j + 1, count do
				local n3 = planes[k].normal
				local x3, y3, z3, d3 = n3.x, n3.y, n3.z, planes[k].dist
				-- n2 x n3, n3 x n1 and n1 x n2
				local ax, ay, az = y2 * z3 - z2 * y3, z2 * x3 - x2 * z3, x2 * y3 - y2 * x3
				local bx, by, bz = y3 * z1 - z3 * y1, z3 * x1 - x3 * z1, x3 * y1 - y3 * x1
				local cx, cy, cz = y1 * z2 - z1 * y2, z1 * x2 - x1 * z2, x1 * y2 - y1 * x2
				local determinant = x1 * ax + y1 * ay + z1 * az

				if math.abs(determinant) > 0.000001 then
					local px = (ax * d1 + bx * d2 + cx * d3) / determinant
					local py = (ay * d1 + by * d2 + cy * d3) / determinant
					local pz = (az * d1 + bz * d2 + cz * d3) / determinant
					local inside = true

					for m = 1, count do
						local plane = planes[m]
						local n = plane.normal

						if px * n.x + py * n.y + pz * n.z - plane.dist > epsilon then
							inside = false

							break
						end
					end

					if inside then points[#points + 1] = Vec3(px, py, pz) end
				end
			end
		end
	end

	if #points < 4 then return nil end

	return convex_hull.BuildFromPlanes(points, planes, epsilon)
end

return brush_hull
