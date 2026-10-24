local convex_hull = import("goluwa/physics/convex_hull.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local brush_hull = {}
local BRUSH_HULL_EPSILON = 0.0001

do
	local function triple_product(x1, y1, z1, x2, y2, z2, x3, y3, z3)
		return x1 * (y2 * z3 - z2 * y3) + y1 * (z2 * x3 - x2 * z3) + z1 * (x2 * y3 - y2 * x3)
	end

	local function intersect_planes(n1, d1, n2, d2, n3, d3, determinant)
		local x1, y1, z1, x2, y2, z2, x3, y3, z3 = n1.x, n1.y, n1.z, n2.x, n2.y, n2.z, n3.x, n3.y, n3.z
		local ax, ay, az = y2 * z3 - z2 * y3, z2 * x3 - x2 * z3, x2 * y3 - y2 * x3
		local bx, by, bz = y3 * z1 - z3 * y1, z3 * x1 - x3 * z1, x3 * y1 - y3 * x1
		local cx, cy, cz = y1 * z2 - z1 * y2, z1 * x2 - x1 * z2, x1 * y2 - y1 * x2
		return (ax * d1 + bx * d2 + cx * d3) / determinant,
		(ay * d1 + by * d2 + cy * d3) / determinant,
		(az * d1 + bz * d2 + cz * d3) / determinant
	end

	function brush_hull.BuildHullFromPlanes(planes, epsilon)
		if not (planes and planes[1] and planes[4]) then return nil end

		epsilon = epsilon or BRUSH_HULL_EPSILON
		local points = {}
		local count = #planes

		for i = 1, count - 2 do
			local n1 = planes[i].normal
			local x1, y1, z1 = n1.x, n1.y, n1.z

			for j = i + 1, count - 1 do
				local n2 = planes[j].normal
				local x2, y2, z2 = n2.x, n2.y, n2.z

				for k = j + 1, count do
					local n3 = planes[k].normal
					local determinant = triple_product(x1, y1, z1, x2, y2, z2, n3.x, n3.y, n3.z)

					if math.abs(determinant) > 0.000001 then
						local px, py, pz = intersect_planes(n1, planes[i].dist, n2, planes[j].dist, n3, planes[k].dist, determinant)
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
end

return brush_hull
