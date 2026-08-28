-- allocation-free scalar triangle distance kernels for sweep predicates.
-- these operate on plain numbers and never construct Vec3s, take square
-- roots, or normalize: callers compare squared distances and only pay for
-- a real normal when a contact is actually built.
local triangle_scalar = {}

-- signed-area test of the three directed edges (a->b, b->c, c->a): the
-- point (assumed on the plane) is inside when all cross products face the
-- normal
local function point_in_triangle_fast_path(x, y, z, ax, ay, az, bx, by, bz, cx, cy, cz, nx, ny, nz, epsilon)
	local pax = x - ax
	local pay = y - ay
	local paz = z - az
	local ex = bx - ax
	local ey = by - ay
	local ez = bz - az
	local cx1 = ey * paz - ez * pay
	local cy1 = ez * pax - ex * paz
	local cz1 = ex * pay - ey * pax
	pax = x - bx
	pay = y - by
	paz = z - bz
	ex = cx - bx
	ey = cy - by
	ez = cz - bz
	local cx2 = ey * paz - ez * pay
	local cy2 = ez * pax - ex * paz
	local cz2 = ex * pay - ey * pax
	pax = x - cx
	pay = y - cy
	paz = z - cz
	ex = ax - cx
	ey = ay - cy
	ez = az - cz
	local cx3 = ey * paz - ez * pay
	local cy3 = ez * pax - ex * paz
	local cz3 = ex * pay - ey * pax
	return cx1 * nx + cy1 * ny + cz1 * nz >= -epsilon and
		(
			cx2 * nx + cy2 * ny + cz2 * nz >= -epsilon
		)
		and
		(
			cx3 * nx + cy3 * ny + cz3 * nz >= -epsilon
		)
end

-- unnormalized face normal (v1-v0) x (v2-v0) and its squared length; the
-- squared length is the degeneracy measure and keeps sign tests free of a
-- sqrt
function triangle_scalar.TriangleNormalRaw(v0x, v0y, v0z, v1x, v1y, v1z, v2x, v2y, v2z)
	local abx = v1x - v0x
	local aby = v1y - v0y
	local abz = v1z - v0z
	local acx = v2x - v0x
	local acy = v2y - v0y
	local acz = v2z - v0z
	local nx = aby * acz - abz * acy
	local ny = abz * acx - abx * acz
	local nz = abx * acy - aby * acx
	return nx, ny, nz, nx * nx + ny * ny + nz * nz
end

-- closest squared distance from point p to segment ab; returns the closest
-- point on the segment
function triangle_scalar.PointToSegmentSq(x, y, z, ax, ay, az, bx, by, bz)
	local dx = bx - ax
	local dy = by - ay
	local dz = bz - az
	local l2 = dx * dx + dy * dy + dz * dz
	local lambda = 0

	if l2 > 0 then
		lambda = ((x - ax) * dx + (y - ay) * dy + (z - az) * dz) / l2

		if lambda < 0 then lambda = 0 elseif lambda > 1 then lambda = 1 end
	end

	local qx = ax + dx * lambda
	local qy = ay + dy * lambda
	local qz = az + dz * lambda
	local ddx = x - qx
	local ddy = y - qy
	local ddz = z - qz
	return ddx * ddx + ddy * ddy + ddz * ddz, qx, qy, qz
end

-- closest squared distance between segment ab and segment cd. returns the
-- squared distance and the closest point on each segment.
function triangle_scalar.SegmentSegmentSq(ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz)
	local ux = bx - ax
	local uy = by - ay
	local uz = bz - az
	local wx = dx - cx
	local wy = dy - cy
	local wz = dz - cz
	local vx = cx - ax
	local vy = cy - ay
	local vz = cz - az
	local acoef = ux * ux + uy * uy + uz * uz
	local bcoef = ux * vx + uy * vy + uz * vz
	local dcoef = ux * wx + uy * wy + uz * wz
	local ecoef = wx * wx + wy * wy + wz * wz
	local fcoef = wx * vx + wy * vy + wz * vz

	if acoef <= 1e-12 then
		local sq, qx, qy, qz = triangle_scalar.PointToSegmentSq(ax, ay, az, cx, cy, cz, dx, dy, dz)
		return sq, ax, ay, az, qx, qy, qz
	end

	if ecoef <= 1e-12 then
		local sq, qx, qy, qz = triangle_scalar.PointToSegmentSq(cx, cy, cz, ax, ay, az, bx, by, bz)
		return sq, qx, qy, qz, cx, cy, cz
	end

	if acoef * ecoef <= dcoef * dcoef then
		-- parallel: the minimum lies on one of the two boundary slices, both
		-- covered by projecting one segment's start point onto the other
		local sq1, qx1, qy1, qz1 = triangle_scalar.PointToSegmentSq(ax, ay, az, cx, cy, cz, dx, dy, dz)
		local sq2, qx2, qy2, qz2 = triangle_scalar.PointToSegmentSq(cx, cy, cz, ax, ay, az, bx, by, bz)

		if sq1 < sq2 then return sq1, ax, ay, az, qx1, qy1, qz1 end

		return sq2, qx2, qy2, qz2, cx, cy, cz
	end

	-- interior solution of a*s - d*t = b, -d*s + e*t = -f
	local det = acoef * ecoef - dcoef * dcoef
	local s = (bcoef * ecoef - dcoef * fcoef) / det
	local t = (bcoef * dcoef - acoef * fcoef) / det

	if s < 0 then
		s = 0
		t = -fcoef / ecoef
	elseif s > 1 then
		s = 1
		t = (dcoef - fcoef) / ecoef
	end

	if t < 0 then
		t = 0
		s = bcoef / acoef
	elseif t > 1 then
		t = 1
		s = (bcoef + dcoef) / acoef
	end

	if s < 0 then s = 0 elseif s > 1 then s = 1 end

	local p1x = ax + ux * s
	local p1y = ay + uy * s
	local p1z = az + uz * s
	local p2x = cx + wx * t
	local p2y = cy + wy * t
	local p2z = cz + wz * t
	local pxd = p1x - p2x
	local pyd = p1y - p2y
	local pzdz = p1z - p2z
	return pxd * pxd + pyd * pyd + pzdz * pzdz, p1x, p1y, p1z, p2x, p2y, p2z
end

function triangle_scalar.PointToTriangleSq(x, y, z, ax, ay, az, bx, by, bz, cx, cy, cz)
	local abx = bx - ax
	local aby = by - ay
	local abz = bz - az
	local acx = cx - ax
	local acy = cy - ay
	local acz = cz - az
	local apx = x - ax
	local apy = y - ay
	local apz = z - az
	local d1 = abx * apx + aby * apy + abz * apz
	local d2 = acx * apx + acy * apy + acz * apz

	-- vertex a region
	if d1 <= 0 and d2 <= 0 then
		local ddx = x - ax
		local ddy = y - ay
		local ddz = z - az
		return ddx * ddx + ddy * ddy + ddz * ddz, ax, ay, az
	end

	-- vertex b region
	local bpx = x - bx
	local bpy = y - by
	local bpz = z - bz
	local d3 = abx * bpx + aby * bpy + abz * bpz
	local d4 = acx * bpx + acy * bpy + acz * bpz

	if d3 >= 0 and d4 <= d3 then
		local ddx = x - bx
		local ddy = y - by
		local ddz = z - bz
		return ddx * ddx + ddy * ddy + ddz * ddz, bx, by, bz
	end

	local vc = d1 * d4 - d3 * d2

	-- edge ab region
	if vc <= 0 and d1 >= 0 and d3 <= 0 then
		local v = d1 / (d1 - d3)
		local qx = ax + abx * v
		local qy = ay + aby * v
		local qz = az + abz * v
		local ddx = x - qx
		local ddy = y - qy
		local ddz = z - qz
		return ddx * ddx + ddy * ddy + ddz * ddz, qx, qy, qz
	end

	-- vertex c region
	local cpx = x - cx
	local cpy = y - cy
	local cpz = z - cz
	local d5 = abx * cpx + aby * cpy + abz * cpz
	local d6 = acx * cpx + acy * cpy + acz * cpz

	if d6 >= 0 and d5 <= d6 then
		local ddx = x - cx
		local ddy = y - cy
		local ddz = cpz
		return ddx * ddx + ddy * ddy + ddz * ddz, cx, cy, cz
	end

	local vb = d5 * d2 - d1 * d6

	-- edge ac region
	if vb <= 0 and d2 >= 0 and d6 <= 0 then
		local w = d2 / (d2 - d6)
		local qx = ax + acx * w
		local qy = ay + acy * w
		local qz = az + acz * w
		local ddx = x - qx
		local ddy = y - qy
		local ddz = z - qz
		return ddx * ddx + ddy * ddy + ddz * ddz, qx, qy, qz
	end

	local va = d3 * d6 - d5 * d4

	-- edge bc region
	if va <= 0 and d4 - d3 >= 0 and d5 - d6 >= 0 then
		local w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
		local qx = bx + (cx - bx) * w
		local qy = by + (cy - by) * w
		local qz = bz + (cz - bz) * w
		local ddx = x - qx
		local ddy = y - qy
		local ddz = z - qz
		return ddx * ddx + ddy * ddy + ddz * ddz, qx, qy, qz
	end

	-- interior: closest point on the infinite plane projected onto the
	-- triangle, which lies inside, so no barycentric solve is needed
	local va2 = d3 * d6 - d5 * d4
	local vb2 = d5 * d2 - d1 * d6
	local vc2 = d1 * d4 - d3 * d2
	local denom = va2 + vb2 + vc2
	local qx = ax + (vb2 * abx + vc2 * acx) / denom
	local qy = ay + (vb2 * aby + vc2 * acy) / denom
	local qz = az + (vb2 * abz + vc2 * acz) / denom
	local ddx = x - qx
	local ddy = y - qy
	local ddz = z - qz
	return ddx * ddx + ddy * ddy + ddz * ddz, qx, qy, qz
end

-- segment to triangle squared distance. returns distance_sq, the closest
-- point on the segment, the closest point on the triangle and a feature
-- discriminator ("face", "vertex" or "edge") so callers can rebuild an
-- exact contact (position + normal) through matching higher-level queries.
-- a nil face_normal skips the plane fast paths and degenerates to the
-- vertex/edge minimum, matching the vector-based pipeline.
function triangle_scalar.SegmentToTriangleSq(
	ax,
	ay,
	az,
	bx,
	by,
	bz,
	v0x,
	v0y,
	v0z,
	v1x,
	v1y,
	v1z,
	v2x,
	v2y,
	v2z,
	face_normal,
	epsilon
)
	epsilon = epsilon or 0.00001

	if face_normal then
		local nx = face_normal.x
		local ny = face_normal.y
		local nz = face_normal.z
		local den = nx * (bx - ax) + ny * (by - ay) + nz * (bz - az)

		if math.abs(den) > epsilon then
			local t = (nx * (v0x - ax) + ny * (v0y - ay) + nz * (v0z - az)) / den

			if t >= 0 and t <= 1 then
				local px = ax + (bx - ax) * t
				local py = ay + (by - ay) * t
				local pz = az + (bz - az) * t

				if
					point_in_triangle_fast_path(px, py, pz, v0x, v0y, v0z, v1x, v1y, v1z, v2x, v2y, v2z, nx, ny, nz, epsilon)
				then
					local sd = (ax - v0x) * nx + (ay - v0y) * ny + (az - v0z) * nz
					local signed = sd + den * t
					local qx = px - nx * signed
					local qy = py - ny * signed
					local qz = pz - nz * signed
					local dd = signed * signed
					return dd, px, py, pz, qx, qy, qz, "face"
				end
			end
		end
	end

	local best_sq = math.huge
	local best_sx, best_sy, best_sz, best_qx, best_qy, best_qz, best_feature
	local sq, qx, qy, qz = triangle_scalar.PointToTriangleSq(ax, ay, az, v0x, v0y, v0z, v1x, v1y, v1z, v2x, v2y, v2z)

	if sq < best_sq then
		best_sq, best_sx, best_sy, best_sz, best_qx, best_qy, best_qz, best_feature = sq, ax, ay, az, qx, qy, qz, "point"
	end

	sq, qx, qy, qz = triangle_scalar.PointToTriangleSq(bx, by, bz, v0x, v0y, v0z, v1x, v1y, v1z, v2x, v2y, v2z)

	if sq < best_sq then
		best_sq, best_sx, best_sy, best_sz, best_qx, best_qy, best_qz, best_feature = sq, bx, by, bz, qx, qy, qz, "point"
	end

	sq, px, py, pz, qx, qy, qz = triangle_scalar.SegmentSegmentSq(ax, ay, az, bx, by, bz, v0x, v0y, v0z, v1x, v1y, v1z)

	if sq < best_sq then
		best_sq, best_sx, best_sy, best_sz, best_qx, best_qy, best_qz, best_feature = sq, px, py, pz, qx, qy, qz, "edge"
	end

	sq, px, py, pz, qx, qy, qz = triangle_scalar.SegmentSegmentSq(ax, ay, az, bx, by, bz, v1x, v1y, v1z, v2x, v2y, v2z)

	if sq < best_sq then
		best_sq, best_sx, best_sy, best_sz, best_qx, best_qy, best_qz, best_feature = sq, px, py, pz, qx, qy, qz, "edge"
	end

	sq, px, py, pz, qx, qy, qz = triangle_scalar.SegmentSegmentSq(ax, ay, az, bx, by, bz, v2x, v2y, v2z, v0x, v0y, v0z)

	if sq < best_sq then
		best_sq, best_sx, best_sy, best_sz, best_qx, best_qy, best_qz, best_feature = sq, px, py, pz, qx, qy, qz, "edge"
	end

	return best_sq,
	best_sx,
	best_sy,
	best_sz,
	best_qx,
	best_qy,
	best_qz,
	best_feature
end

return triangle_scalar
