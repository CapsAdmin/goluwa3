local ffi = require("ffi")
local vertex_math = {}
vertex_math.VertexType = ffi.typeof([[
	struct {
		float position[3];
		float normal[3];
		float uv[2];
		float tangent[4];
		float texture_blend;
		float vertex_color[4];
	}[?]
]])
local sqrt, abs = math.sqrt, math.abs
local TANGENT_EPSILON = 1e-9
local double_array_t = ffi.typeof("double[?]")
local uint8_array_t = ffi.typeof("uint8_t[?]")

function vertex_math.BuildTangents(vertices, vertex_count, indices, index_count)
	local tan1 = double_array_t(vertex_count * 3)
	local tan2 = double_array_t(vertex_count * 3)
	local touched = uint8_array_t(vertex_count)

	for i = 0, index_count - 3, 3 do
		local ai, bi, ci = indices[i], indices[i + 1], indices[i + 2]
		local a, b, c = vertices[ai], vertices[bi], vertices[ci]
		local ap, bp, cp = a.position, b.position, c.position
		local x1, y1, z1 = bp[0] - ap[0], bp[1] - ap[1], bp[2] - ap[2]
		local x2, y2, z2 = cp[0] - ap[0], cp[1] - ap[1], cp[2] - ap[2]
		local s1, t1 = b.uv[0] - a.uv[0], b.uv[1] - a.uv[1]
		local s2, t2 = c.uv[0] - a.uv[0], c.uv[1] - a.uv[1]
		local denom = s1 * t2 - s2 * t1

		if abs(denom) > TANGENT_EPSILON then
			local r = 1 / denom
			local sx, sy, sz = (t2 * x1 - t1 * x2) * r, (t2 * y1 - t1 * y2) * r, (t2 * z1 - t1 * z2) * r
			local tx, ty, tz = (s1 * x2 - s2 * x1) * r, (s1 * y2 - s2 * y1) * r, (s1 * z2 - s2 * z1) * r

			for k = 0, 2 do
				local index = indices[i + k]
				local o = index * 3
				tan1[o], tan1[o + 1], tan1[o + 2] = tan1[o] + sx, tan1[o + 1] + sy, tan1[o + 2] + sz
				tan2[o], tan2[o + 1], tan2[o + 2] = tan2[o] + tx, tan2[o + 1] + ty, tan2[o + 2] + tz
				touched[index] = 1
			end
		end
	end

	for i = 0, vertex_count - 1 do
		local vertex = vertices[i]
		local nx, ny, nz = vertex.normal[0], vertex.normal[1], vertex.normal[2]
		local length = sqrt(nx * nx + ny * ny + nz * nz)

		if length == 0 then
			nx, ny, nz = 0, 0, 0
		else
			nx, ny, nz = nx / length, ny / length, nz / length
		end

		local o = i * 3
		local has_tangent = touched[i] == 1
		local tx, ty, tz, bx, by, bz = 0, 0, 0, 0, 0, 0

		if has_tangent then
			tx, ty, tz = tan1[o], tan1[o + 1], tan1[o + 2]
			bx, by, bz = tan2[o], tan2[o + 1], tan2[o + 2]
			local dot = nx * tx + ny * ty + nz * tz
			tx, ty, tz = tx - nx * dot, ty - ny * dot, tz - nz * dot
		end

		if not has_tangent or tx * tx + ty * ty + tz * tz <= TANGENT_EPSILON then
			local dot = nx * bx + ny * by + nz * bz
			local px, py, pz = bx - nx * dot, by - ny * dot, bz - nz * dot

			if has_tangent and px * px + py * py + pz * pz > TANGENT_EPSILON then
				tx, ty, tz = py * nz - pz * ny, pz * nx - px * nz, px * ny - py * nx
				has_tangent = true
			else
				has_tangent = false
			end
		end

		if not has_tangent or tx * tx + ty * ty + tz * tz <= TANGENT_EPSILON then
			local rx, ry, rz = 0, 1, 0

			if abs(ny) >= 0.999 then rx, ry, rz = 1, 0, 0 end

			tx, ty, tz = ry * nz - rz * ny, rz * nx - rx * nz, rx * ny - ry * nx
		end

		length = sqrt(tx * tx + ty * ty + tz * tz)

		if length == 0 then
			tx, ty, tz = 0, 0, 0
		else
			tx, ty, tz = tx / length, ty / length, tz / length
		end

		local handedness = 1

		if bx * bx + by * by + bz * bz > TANGENT_EPSILON then
			local cx, cy, cz = ny * tz - nz * ty, nz * tx - nx * tz, nx * ty - ny * tx

			if cx * bx + cy * by + cz * bz < 0 then handedness = -1 end
		end

		local tangent = vertex.tangent
		tangent[0], tangent[1], tangent[2], tangent[3] = tx, ty, tz, handedness
	end
end

return vertex_math
