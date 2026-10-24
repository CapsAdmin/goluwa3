local math_min = math.min
local math_max = math.max
local triangle_scalar = {}
local best = {0, 0, 0, 0, 0, 0}

function triangle_scalar.TriangleNormalRaw(v0, v1, v2)
	local abx = v1.x - v0.x
	local aby = v1.y - v0.y
	local abz = v1.z - v0.z
	local acx = v2.x - v0.x
	local acy = v2.y - v0.y
	local acz = v2.z - v0.z
	local nx = aby * acz - abz * acy
	local ny = abz * acx - abx * acz
	local nz = abx * acy - aby * acx
	return nx, ny, nz, nx * nx + ny * ny + nz * nz
end

do
	local function closest_on_edges_or_face(p, a, b, c, d1, d2, d3, d4, d5, d6)
		local vc = d1 * d4 - d3 * d2

		if vc <= 0 and d1 >= 0 and d3 <= 0 then
			local v = d1 / (d1 - d3)
			local qx = a.x + (b.x - a.x) * v
			local qy = a.y + (b.y - a.y) * v
			local qz = a.z + (b.z - a.z) * v
			local ddx = p.x - qx
			local ddy = p.y - qy
			local ddz = p.z - qz
			return ddx * ddx + ddy * ddy + ddz * ddz, qx, qy, qz
		end

		local vb = d5 * d2 - d1 * d6

		if vb <= 0 and d2 >= 0 and d6 <= 0 then
			local w = d2 / (d2 - d6)
			local qx = a.x + (c.x - a.x) * w
			local qy = a.y + (c.y - a.y) * w
			local qz = a.z + (c.z - a.z) * w
			local ddx = p.x - qx
			local ddy = p.y - qy
			local ddz = p.z - qz
			return ddx * ddx + ddy * ddy + ddz * ddz, qx, qy, qz
		end

		local va = d3 * d6 - d5 * d4

		if va <= 0 and d4 - d3 >= 0 and d5 - d6 >= 0 then
			local w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
			local qx = b.x + (c.x - b.x) * w
			local qy = b.y + (c.y - b.y) * w
			local qz = b.z + (c.z - b.z) * w
			local ddx = p.x - qx
			local ddy = p.y - qy
			local ddz = p.z - qz
			return ddx * ddx + ddy * ddy + ddz * ddz, qx, qy, qz
		end

		local denom = va + vb + vc
		local qx = a.x + (vb * (b.x - a.x) + vc * (c.x - a.x)) / denom
		local qy = a.y + (vb * (b.y - a.y) + vc * (c.y - a.y)) / denom
		local qz = a.z + (vb * (b.z - a.z) + vc * (c.z - a.z)) / denom
		local ddx = p.x - qx
		local ddy = p.y - qy
		local ddz = p.z - qz
		return ddx * ddx + ddy * ddy + ddz * ddz, qx, qy, qz
	end

	function triangle_scalar.PointToTriangleSq(p, a, b, c)
		local abx = b.x - a.x
		local aby = b.y - a.y
		local abz = b.z - a.z
		local acx = c.x - a.x
		local acy = c.y - a.y
		local acz = c.z - a.z
		local apx = p.x - a.x
		local apy = p.y - a.y
		local apz = p.z - a.z
		local d1 = abx * apx + aby * apy + abz * apz
		local d2 = acx * apx + acy * apy + acz * apz

		if d1 <= 0 and d2 <= 0 then
			return apx * apx + apy * apy + apz * apz, a.x, a.y, a.z
		end

		local abac = abx * acx + aby * acy + abz * acz
		local d3 = d1 - (abx * abx + aby * aby + abz * abz)
		local d4 = d2 - abac

		if d3 >= 0 and d4 <= d3 then
			local bpx = p.x - b.x
			local bpy = p.y - b.y
			local bpz = p.z - b.z
			return bpx * bpx + bpy * bpy + bpz * bpz, b.x, b.y, b.z
		end

		local d5 = d1 - abac
		local d6 = d2 - (acx * acx + acy * acy + acz * acz)

		if d6 >= 0 and d5 <= d6 then
			local cpx = p.x - c.x
			local cpy = p.y - c.y
			local cpz = p.z - c.z
			return cpx * cpx + cpy * cpy + cpz * cpz, c.x, c.y, c.z
		end

		return closest_on_edges_or_face(p, a, b, c, d1, d2, d3, d4, d5, d6)
	end
end

do
	local function point_to_segment_sq(p, a, b)
		local dx = b.x - a.x
		local dy = b.y - a.y
		local dz = b.z - a.z
		local l2 = dx * dx + dy * dy + dz * dz
		local lambda = math_min(
			math_max(((p.x - a.x) * dx + (p.y - a.y) * dy + (p.z - a.z) * dz) / math_max(l2, 1e-30), 0),
			1
		)
		local qx = a.x + dx * lambda
		local qy = a.y + dy * lambda
		local qz = a.z + dz * lambda
		local ddx = p.x - qx
		local ddy = p.y - qy
		local ddz = p.z - qz
		return ddx * ddx + ddy * ddy + ddz * ddz, qx, qy, qz
	end

	local function segment_segment_sq(a, b, c, d)
		local ux = b.x - a.x
		local uy = b.y - a.y
		local uz = b.z - a.z
		local wx = d.x - c.x
		local wy = d.y - c.y
		local wz = d.z - c.z
		local vx = c.x - a.x
		local vy = c.y - a.y
		local vz = c.z - a.z
		local acoef = ux * ux + uy * uy + uz * uz
		local bcoef = ux * vx + uy * vy + uz * vz
		local dcoef = ux * wx + uy * wy + uz * wz
		local ecoef = wx * wx + wy * wy + wz * wz
		local fcoef = wx * vx + wy * vy + wz * vz

		if acoef <= 1e-12 then
			local sq, qx, qy, qz = point_to_segment_sq(a, c, d)
			return sq, a.x, a.y, a.z, qx, qy, qz
		end

		if ecoef <= 1e-12 then
			local sq, qx, qy, qz = point_to_segment_sq(c, a, b)
			return sq, qx, qy, qz, c.x, c.y, c.z
		end

		if acoef * ecoef <= dcoef * dcoef then
			local sq1, qx1, qy1, qz1 = point_to_segment_sq(a, c, d)
			local sq2, qx2, qy2, qz2 = point_to_segment_sq(c, a, b)

			if sq1 < sq2 then return sq1, a.x, a.y, a.z, qx1, qy1, qz1 end

			return sq2, qx2, qy2, qz2, c.x, c.y, c.z
		end

		local s = math_min(math_max((bcoef * ecoef - dcoef * fcoef) / (acoef * ecoef - dcoef * dcoef), 0), 1)
		local t = math_min(math_max((s * dcoef - fcoef) / ecoef, 0), 1)
		s = math_min(math_max((t * dcoef + bcoef) / acoef, 0), 1)
		local p1x = a.x + ux * s
		local p1y = a.y + uy * s
		local p1z = a.z + uz * s
		local p2x = c.x + wx * t
		local p2y = c.y + wy * t
		local p2z = c.z + wz * t
		local pxd = p1x - p2x
		local pyd = p1y - p2y
		local pzdz = p1z - p2z
		return pxd * pxd + pyd * pyd + pzdz * pzdz, p1x, p1y, p1z, p2x, p2y, p2z
	end

	function triangle_scalar.SegmentToTriangleSq(a, b, v0, v1, v2, face_normal, epsilon)
		epsilon = epsilon or 0.00001

		if face_normal then
			local den = face_normal.x * (
					b.x - a.x
				) + face_normal.y * (
					b.y - a.y
				) + face_normal.z * (
					b.z - a.z
				)

			if math.abs(den) > epsilon then
				local t = (
						face_normal.x * (
							v0.x - a.x
						) + face_normal.y * (
							v0.y - a.y
						) + face_normal.z * (
							v0.z - a.z
						)
					) / den

				if t >= 0 and t <= 1 then
					local px = a.x + (b.x - a.x) * t
					local py = a.y + (b.y - a.y) * t
					local pz = a.z + (b.z - a.z) * t
					local pax = px - v0.x
					local pay = py - v0.y
					local paz = pz - v0.z
					local ex = v1.x - v0.x
					local ey = v1.y - v0.y
					local ez = v1.z - v0.z

					if
						(
							ey * paz - ez * pay
						) * face_normal.x + (
							ez * pax - ex * paz
						) * face_normal.y + (
							ex * pay - ey * pax
						) * face_normal.z >= -epsilon
					then
						pax = px - v1.x
						pay = py - v1.y
						paz = pz - v1.z
						ex = v2.x - v1.x
						ey = v2.y - v1.y
						ez = v2.z - v1.z

						if
							(
								ey * paz - ez * pay
							) * face_normal.x + (
								ez * pax - ex * paz
							) * face_normal.y + (
								ex * pay - ey * pax
							) * face_normal.z >= -epsilon
						then
							pax = px - v2.x
							pay = py - v2.y
							paz = pz - v2.z
							ex = v0.x - v2.x
							ey = v0.y - v2.y
							ez = v0.z - v2.z

							if
								(
									ey * paz - ez * pay
								) * face_normal.x + (
									ez * pax - ex * paz
								) * face_normal.y + (
									ex * pay - ey * pax
								) * face_normal.z >= -epsilon
							then
								local signed = (
										a.x - v0.x
									) * face_normal.x + (
										a.y - v0.y
									) * face_normal.y + (
										a.z - v0.z
									) * face_normal.z + den * t
								return signed * signed,
								px,
								py,
								pz,
								px - face_normal.x * signed,
								py - face_normal.y * signed,
								pz - face_normal.z * signed
							end
						end
					end
				end
			end
		end

		local sq, qx, qy, qz = triangle_scalar.PointToTriangleSq(a, v0, v1, v2)
		local best_sq = sq
		best[1], best[2], best[3], best[4], best[5], best[6] = a.x, a.y, a.z, qx, qy, qz
		sq, qx, qy, qz = triangle_scalar.PointToTriangleSq(b, v0, v1, v2)

		if sq < best_sq then
			best_sq = sq
			best[1], best[2], best[3], best[4], best[5], best[6] = b.x, b.y, b.z, qx, qy, qz
		end

		local px, py, pz
		sq, px, py, pz, qx, qy, qz = segment_segment_sq(a, b, v0, v1)

		if sq < best_sq then
			best_sq = sq
			best[1], best[2], best[3], best[4], best[5], best[6] = px, py, pz, qx, qy, qz
		end

		sq, px, py, pz, qx, qy, qz = segment_segment_sq(a, b, v1, v2)

		if sq < best_sq then
			best_sq = sq
			best[1], best[2], best[3], best[4], best[5], best[6] = px, py, pz, qx, qy, qz
		end

		sq, px, py, pz, qx, qy, qz = segment_segment_sq(a, b, v2, v0)

		if sq < best_sq then
			best_sq = sq
			best[1], best[2], best[3], best[4], best[5], best[6] = px, py, pz, qx, qy, qz
		end

		return best_sq, best[1], best[2], best[3], best[4], best[5], best[6]
	end
end

return triangle_scalar
