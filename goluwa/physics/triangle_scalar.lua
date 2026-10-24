local Vec3 = import("goluwa/structs/vec3.lua")
local triangle_scalar = {}
local face_point = Vec3()

local function point_in_triangle_fast_path(p, a, b, c, n, epsilon)
	local nx, ny, nz = n.x, n.y, n.z
	local pax = p.x - a.x
	local pay = p.y - a.y
	local paz = p.z - a.z
	local ex = b.x - a.x
	local ey = b.y - a.y
	local ez = b.z - a.z

	if (ey * paz - ez * pay) * nx + (ez * pax - ex * paz) * ny + (ex * pay - ey * pax) * nz < -epsilon then
		return false
	end

	pax = p.x - b.x
	pay = p.y - b.y
	paz = p.z - b.z
	ex = c.x - b.x
	ey = c.y - b.y
	ez = c.z - b.z

	if (ey * paz - ez * pay) * nx + (ez * pax - ex * paz) * ny + (ex * pay - ey * pax) * nz < -epsilon then
		return false
	end

	pax = p.x - c.x
	pay = p.y - c.y
	paz = p.z - c.z
	ex = a.x - c.x
	ey = a.y - c.y
	ez = a.z - c.z
	return (ey * paz - ez * pay) * nx + (ez * pax - ex * paz) * ny + (ex * pay - ey * pax) * nz >= -epsilon
end

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

function triangle_scalar.PointToSegmentSq(p, a, b)
	local dx = b.x - a.x
	local dy = b.y - a.y
	local dz = b.z - a.z
	local l2 = dx * dx + dy * dy + dz * dz
	local lambda = 0

	if l2 > 0 then
		lambda = ((p.x - a.x) * dx + (p.y - a.y) * dy + (p.z - a.z) * dz) / l2

		if lambda < 0 then lambda = 0 elseif lambda > 1 then lambda = 1 end
	end

	local qx = a.x + dx * lambda
	local qy = a.y + dy * lambda
	local qz = a.z + dz * lambda
	local ddx = p.x - qx
	local ddy = p.y - qy
	local ddz = p.z - qz
	return ddx * ddx + ddy * ddy + ddz * ddz, qx, qy, qz
end

function triangle_scalar.SegmentSegmentSq(a, b, c, d)
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
		local sq, qx, qy, qz = triangle_scalar.PointToSegmentSq(a, c, d)
		return sq, a.x, a.y, a.z, qx, qy, qz
	end

	if ecoef <= 1e-12 then
		local sq, qx, qy, qz = triangle_scalar.PointToSegmentSq(c, a, b)
		return sq, qx, qy, qz, c.x, c.y, c.z
	end

	if acoef * ecoef <= dcoef * dcoef then
		local sq1, qx1, qy1, qz1 = triangle_scalar.PointToSegmentSq(a, c, d)
		local sq2, qx2, qy2, qz2 = triangle_scalar.PointToSegmentSq(c, a, b)

		if sq1 < sq2 then return sq1, a.x, a.y, a.z, qx1, qy1, qz1 end

		return sq2, qx2, qy2, qz2, c.x, c.y, c.z
	end

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

	local bpx = p.x - b.x
	local bpy = p.y - b.y
	local bpz = p.z - b.z
	local d3 = abx * bpx + aby * bpy + abz * bpz
	local d4 = acx * bpx + acy * bpy + acz * bpz

	if d3 >= 0 and d4 <= d3 then
		return bpx * bpx + bpy * bpy + bpz * bpz, b.x, b.y, b.z
	end

	local vc = d1 * d4 - d3 * d2

	if vc <= 0 and d1 >= 0 and d3 <= 0 then
		local v = d1 / (d1 - d3)
		local qx = a.x + abx * v
		local qy = a.y + aby * v
		local qz = a.z + abz * v
		local ddx = p.x - qx
		local ddy = p.y - qy
		local ddz = p.z - qz
		return ddx * ddx + ddy * ddy + ddz * ddz, qx, qy, qz
	end

	local cpx = p.x - c.x
	local cpy = p.y - c.y
	local cpz = p.z - c.z
	local d5 = abx * cpx + aby * cpy + abz * cpz
	local d6 = acx * cpx + acy * cpy + acz * cpz

	if d6 >= 0 and d5 <= d6 then
		return cpx * cpx + cpy * cpy + cpz * cpz, c.x, c.y, c.z
	end

	local vb = d5 * d2 - d1 * d6

	if vb <= 0 and d2 >= 0 and d6 <= 0 then
		local w = d2 / (d2 - d6)
		local qx = a.x + acx * w
		local qy = a.y + acy * w
		local qz = a.z + acz * w
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
	local qx = a.x + (vb * abx + vc * acx) / denom
	local qy = a.y + (vb * aby + vc * acy) / denom
	local qz = a.z + (vb * abz + vc * acz) / denom
	local ddx = p.x - qx
	local ddy = p.y - qy
	local ddz = p.z - qz
	return ddx * ddx + ddy * ddy + ddz * ddz, qx, qy, qz
end

function triangle_scalar.SegmentToTriangleSq(a, b, v0, v1, v2, face_normal, epsilon)
	epsilon = epsilon or 0.00001

	if face_normal then
		local nx = face_normal.x
		local ny = face_normal.y
		local nz = face_normal.z
		local den = nx * (b.x - a.x) + ny * (b.y - a.y) + nz * (b.z - a.z)

		if math.abs(den) > epsilon then
			local t = (nx * (v0.x - a.x) + ny * (v0.y - a.y) + nz * (v0.z - a.z)) / den

			if t >= 0 and t <= 1 then
				local px = a.x + (b.x - a.x) * t
				local py = a.y + (b.y - a.y) * t
				local pz = a.z + (b.z - a.z) * t
				face_point.x, face_point.y, face_point.z = px, py, pz

				if point_in_triangle_fast_path(face_point, v0, v1, v2, face_normal, epsilon) then
					local signed = (a.x - v0.x) * nx + (a.y - v0.y) * ny + (a.z - v0.z) * nz + den * t
					return signed * signed,
					px,
					py,
					pz,
					px - nx * signed,
					py - ny * signed,
					pz - nz * signed,
					"face"
				end
			end
		end
	end

	local best_sq = math.huge
	local best_sx, best_sy, best_sz, best_qx, best_qy, best_qz, best_feature
	local sq, qx, qy, qz = triangle_scalar.PointToTriangleSq(a, v0, v1, v2)

	if sq < best_sq then
		best_sq, best_sx, best_sy, best_sz, best_qx, best_qy, best_qz, best_feature = sq, a.x, a.y, a.z, qx, qy, qz, "point"
	end

	sq, qx, qy, qz = triangle_scalar.PointToTriangleSq(b, v0, v1, v2)

	if sq < best_sq then
		best_sq, best_sx, best_sy, best_sz, best_qx, best_qy, best_qz, best_feature = sq, b.x, b.y, b.z, qx, qy, qz, "point"
	end

	local px, py, pz
	sq, px, py, pz, qx, qy, qz = triangle_scalar.SegmentSegmentSq(a, b, v0, v1)

	if sq < best_sq then
		best_sq, best_sx, best_sy, best_sz, best_qx, best_qy, best_qz, best_feature = sq, px, py, pz, qx, qy, qz, "edge"
	end

	sq, px, py, pz, qx, qy, qz = triangle_scalar.SegmentSegmentSq(a, b, v1, v2)

	if sq < best_sq then
		best_sq, best_sx, best_sy, best_sz, best_qx, best_qy, best_qz, best_feature = sq, px, py, pz, qx, qy, qz, "edge"
	end

	sq, px, py, pz, qx, qy, qz = triangle_scalar.SegmentSegmentSq(a, b, v2, v0)

	if sq < best_sq then
		best_sq, best_sx, best_sy, best_sz, best_qx, best_qy, best_qz, best_feature = sq, px, py, pz, qx, qy, qz, "edge"
	end

	return best_sq, best_sx, best_sy, best_sz, best_qx, best_qy, best_qz, best_feature
end

return triangle_scalar
