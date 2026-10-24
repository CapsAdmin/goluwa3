local math_min = math.min
local math_max = math.max
-- a call to a builtin LuaJIT cannot record splits the trace there, which keeps one segment-triangle query from overflowing the 128 number spill slots of a trace
local trace_break = jit.status
local triangle_scalar = {}
local best = {0, 0, 0, 0, 0, 0, 0}
local region = {0, 0, 0, 0, 0, 0}
local seg = {0, 0, 0, 0, 0, 0}

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

function triangle_scalar.PointToTriangleSq(px, py, pz, a, b, c)
	do
		local abx = b.x - a.x
		local aby = b.y - a.y
		local abz = b.z - a.z
		local acx = c.x - a.x
		local acy = c.y - a.y
		local acz = c.z - a.z
		local apx = px - a.x
		local apy = py - a.y
		local apz = pz - a.z
		local d1 = abx * apx + aby * apy + abz * apz
		local d2 = acx * apx + acy * apy + acz * apz
		local abac = abx * acx + aby * acy + abz * acz
		region[1] = d1
		region[2] = d2
		region[3] = d1 - (abx * abx + aby * aby + abz * abz)
		region[4] = d2 - abac
		region[5] = d1 - abac
		region[6] = d2 - (acx * acx + acy * acy + acz * acz)
	end

	if region[1] <= 0 and region[2] <= 0 then
		local apx = px - a.x
		local apy = py - a.y
		local apz = pz - a.z
		return apx * apx + apy * apy + apz * apz, a.x, a.y, a.z
	end

	if region[3] >= 0 and region[4] <= region[3] then
		local bpx = px - b.x
		local bpy = py - b.y
		local bpz = pz - b.z
		return bpx * bpx + bpy * bpy + bpz * bpz, b.x, b.y, b.z
	end

	if region[6] >= 0 and region[5] <= region[6] then
		local cpx = px - c.x
		local cpy = py - c.y
		local cpz = pz - c.z
		return cpx * cpx + cpy * cpy + cpz * cpz, c.x, c.y, c.z
	end

	local qx, qy, qz

	do
		local vc = region[1] * region[4] - region[3] * region[2]

		if vc <= 0 and region[1] >= 0 and region[3] <= 0 then
			local v = region[1] / (region[1] - region[3])
			qx, qy, qz = a.x + (b.x - a.x) * v, a.y + (b.y - a.y) * v, a.z + (b.z - a.z) * v
		else
			local vb = region[5] * region[2] - region[1] * region[6]

			if vb <= 0 and region[2] >= 0 and region[6] <= 0 then
				local w = region[2] / (region[2] - region[6])
				qx, qy, qz = a.x + (c.x - a.x) * w, a.y + (c.y - a.y) * w, a.z + (c.z - a.z) * w
			else
				local va = region[3] * region[6] - region[5] * region[4]

				if va <= 0 and region[4] - region[3] >= 0 and region[5] - region[6] >= 0 then
					local w = (region[4] - region[3]) / ((region[4] - region[3]) + (region[5] - region[6]))
					qx, qy, qz = b.x + (c.x - b.x) * w, b.y + (c.y - b.y) * w, b.z + (c.z - b.z) * w
				else
					local denom = va + vb + vc
					qx, qy, qz = a.x + (vb * (b.x - a.x) + vc * (c.x - a.x)) / denom,
					a.y + (vb * (b.y - a.y) + vc * (c.y - a.y)) / denom,
					a.z + (vb * (b.z - a.z) + vc * (c.z - a.z)) / denom
				end
			end
		end
	end

	local ddx = px - qx
	local ddy = py - qy
	local ddz = pz - qz
	return ddx * ddx + ddy * ddy + ddz * ddz, qx, qy, qz
end

do
	local function point_to_segment_sq(px, py, pz, ax, ay, az, bx, by, bz)
		local dx = bx - ax
		local dy = by - ay
		local dz = bz - az
		local l2 = dx * dx + dy * dy + dz * dz
		local lambda = math_min(
			math_max(((px - ax) * dx + (py - ay) * dy + (pz - az) * dz) / math_max(l2, 1e-30), 0),
			1
		)
		local qx = ax + dx * lambda
		local qy = ay + dy * lambda
		local qz = az + dz * lambda
		local ddx = px - qx
		local ddy = py - qy
		local ddz = pz - qz
		return ddx * ddx + ddy * ddy + ddz * ddz, qx, qy, qz
	end

	local function segment_segment_sq(ax, ay, az, bx, by, bz, c, d)
		local ux = bx - ax
		local uy = by - ay
		local uz = bz - az
		local wx = d.x - c.x
		local wy = d.y - c.y
		local wz = d.z - c.z
		local vx = c.x - ax
		local vy = c.y - ay
		local vz = c.z - az
		local acoef = ux * ux + uy * uy + uz * uz
		local bcoef = ux * vx + uy * vy + uz * vz
		local dcoef = ux * wx + uy * wy + uz * wz
		local ecoef = wx * wx + wy * wy + wz * wz
		local fcoef = wx * vx + wy * vy + wz * vz

		if acoef <= 1e-12 then
			local sq, qx, qy, qz = point_to_segment_sq(ax, ay, az, c.x, c.y, c.z, d.x, d.y, d.z)
			return sq, ax, ay, az, qx, qy, qz
		end

		if ecoef <= 1e-12 then
			local sq, qx, qy, qz = point_to_segment_sq(c.x, c.y, c.z, ax, ay, az, bx, by, bz)
			return sq, qx, qy, qz, c.x, c.y, c.z
		end

		if acoef * ecoef <= dcoef * dcoef then
			local sq1, qx1, qy1, qz1 = point_to_segment_sq(ax, ay, az, c.x, c.y, c.z, d.x, d.y, d.z)
			local sq2, qx2, qy2, qz2 = point_to_segment_sq(c.x, c.y, c.z, ax, ay, az, bx, by, bz)

			if sq1 < sq2 then return sq1, ax, ay, az, qx1, qy1, qz1 end

			return sq2, qx2, qy2, qz2, c.x, c.y, c.z
		end

		local s = math_min(math_max((bcoef * ecoef - dcoef * fcoef) / (acoef * ecoef - dcoef * dcoef), 0), 1)
		local t = math_min(math_max((s * dcoef - fcoef) / ecoef, 0), 1)
		s = math_min(math_max((t * dcoef + bcoef) / acoef, 0), 1)
		local p1x = ax + ux * s
		local p1y = ay + uy * s
		local p1z = az + uz * s
		local p2x = c.x + wx * t
		local p2y = c.y + wy * t
		local p2z = c.z + wz * t
		local pxd = p1x - p2x
		local pyd = p1y - p2y
		local pzdz = p1z - p2z
		return pxd * pxd + pyd * pyd + pzdz * pzdz, p1x, p1y, p1z, p2x, p2y, p2z
	end

	function triangle_scalar.SegmentToTriangleSq(ax, ay, az, bx, by, bz, v0, v1, v2, face_normal, epsilon)
		epsilon = epsilon or 0.00001

		if face_normal then
			local den = face_normal.x * (
					bx - ax
				) + face_normal.y * (
					by - ay
				) + face_normal.z * (
					bz - az
				)

			if math.abs(den) > epsilon then
				local t = (
						face_normal.x * (
							v0.x - ax
						) + face_normal.y * (
							v0.y - ay
						) + face_normal.z * (
							v0.z - az
						)
					) / den

				if t >= 0 and t <= 1 then
					local px = ax + (bx - ax) * t
					local py = ay + (by - ay) * t
					local pz = az + (bz - az) * t
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
										ax - v0.x
									) * face_normal.x + (
										ay - v0.y
									) * face_normal.y + (
										az - v0.z
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

		face_normal = nil
		-- the segment lives in memory from here on so side traces of the candidate tests do not inherit it
		seg[1], seg[2], seg[3], seg[4], seg[5], seg[6] = ax, ay, az, bx, by, bz
		ax, ay, az, bx, by, bz = nil, nil, nil, nil, nil, nil

		do
			local sq, qx, qy, qz = triangle_scalar.PointToTriangleSq(seg[1], seg[2], seg[3], v0, v1, v2)
			best[7] = sq
			best[1], best[2], best[3], best[4], best[5], best[6] = seg[1], seg[2], seg[3], qx, qy, qz
		end

		do
			local sq, qx, qy, qz = triangle_scalar.PointToTriangleSq(seg[4], seg[5], seg[6], v0, v1, v2)

			if sq < best[7] then
				best[7] = sq
				best[1], best[2], best[3], best[4], best[5], best[6] = seg[4], seg[5], seg[6], qx, qy, qz
			end
		end

		trace_break()

		do
			local sq, px, py, pz, qx, qy, qz = segment_segment_sq(seg[1], seg[2], seg[3], seg[4], seg[5], seg[6], v0, v1)

			if sq < best[7] then
				best[7] = sq
				best[1], best[2], best[3], best[4], best[5], best[6] = px, py, pz, qx, qy, qz
			end
		end

		do
			local sq, px, py, pz, qx, qy, qz = segment_segment_sq(seg[1], seg[2], seg[3], seg[4], seg[5], seg[6], v1, v2)

			if sq < best[7] then
				best[7] = sq
				best[1], best[2], best[3], best[4], best[5], best[6] = px, py, pz, qx, qy, qz
			end
		end

		trace_break()

		do
			local sq, px, py, pz, qx, qy, qz = segment_segment_sq(seg[1], seg[2], seg[3], seg[4], seg[5], seg[6], v2, v0)

			if sq < best[7] then
				best[7] = sq
				best[1], best[2], best[3], best[4], best[5], best[6] = px, py, pz, qx, qy, qz
			end
		end

		return best[7], best[1], best[2], best[3], best[4], best[5], best[6]
	end
end

return triangle_scalar
