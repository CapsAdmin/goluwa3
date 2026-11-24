local ffi = require("ffi")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local tint_mesh = {}
local VertexType = vertex_layout.ArrayType
tint_mesh.VERTEX_SIZE = ffi.sizeof(VertexType(1))
local VERTEX_SIZE = tint_mesh.VERTEX_SIZE
local Index32Array = ffi.typeof("uint32_t[?]")

function tint_mesh.New()
	return {
		vertices = VertexType(1024),
		capacity = 1024,
		count = 0,
		indices = Index32Array(2048),
		index_capacity = 2048,
		index_count = 0,
		color = {1, 1, 1},
	}
end

function tint_mesh.Reserve(mesh, vertices, indices)
	if mesh.count + vertices > mesh.capacity then
		local capacity = math.max(mesh.capacity * 2, mesh.count + vertices)
		local grown = VertexType(capacity)
		ffi.copy(grown, mesh.vertices, VERTEX_SIZE * mesh.count)
		mesh.vertices, mesh.capacity = grown, capacity
	end

	if mesh.index_count + indices > mesh.index_capacity then
		local capacity = math.max(mesh.index_capacity * 2, mesh.index_count + indices)
		local grown = Index32Array(capacity)
		ffi.copy(grown, mesh.indices, 4 * mesh.index_count)
		mesh.indices, mesh.index_capacity = grown, capacity
	end
end

function tint_mesh.SetColor(mesh, r, g, b)
	mesh.color[1], mesh.color[2], mesh.color[3] = r, g, b
end

function tint_mesh.AddVertex(mesh, x, y, z, nx, ny, nz, u, v, tx, tz)
	local vertex = mesh.vertices[mesh.count]
	local color = mesh.color
	vertex.vertex_color[0], vertex.vertex_color[1], vertex.vertex_color[2], vertex.vertex_color[3] = color[1], color[2], color[3], 1
	vertex.position[0], vertex.position[1], vertex.position[2] = x, y, z
	vertex.normal[0], vertex.normal[1], vertex.normal[2] = nx, ny, nz
	vertex.uv[0], vertex.uv[1] = u, v
	vertex.tangent[0], vertex.tangent[1], vertex.tangent[2], vertex.tangent[3] = tx, 0, tz, -1
	mesh.count = mesh.count + 1
	return mesh.count - 1
end

-- front faces wind so that (b - a) x (c - a) points away from their normal, as the terrain's do
function tint_mesh.AddTriangle(mesh, a, b, c)
	local i = mesh.index_count
	mesh.indices[i], mesh.indices[i + 1], mesh.indices[i + 2] = a, b, c
	mesh.index_count = i + 3
end

-- corners counter clockwise seen from the front
function tint_mesh.AddQuad(mesh, ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, nx, ny, nz)
	tint_mesh.Reserve(mesh, 4, 6)
	local tx, tz = bx - ax, bz - az
	local length = math.sqrt(tx * tx + tz * tz)

	if length > 1e-6 then tx, tz = tx / length, tz / length else tx, tz = 1, 0 end

	local a = tint_mesh.AddVertex(mesh, ax, ay, az, nx, ny, nz, 0, 0, tx, tz)
	local b = tint_mesh.AddVertex(mesh, bx, by, bz, nx, ny, nz, 1, 0, tx, tz)
	local c = tint_mesh.AddVertex(mesh, cx, cy, cz, nx, ny, nz, 1, 1, tx, tz)
	local d = tint_mesh.AddVertex(mesh, dx, dy, dz, nx, ny, nz, 0, 1, tx, tz)
	tint_mesh.AddTriangle(mesh, a, c, b)
	tint_mesh.AddTriangle(mesh, a, d, c)
end

function tint_mesh.AddWall(mesh, ax, y0a, az, bx, y0b, bz, height, half_width)
	local dx, dz = bx - ax, bz - az
	local length = math.sqrt(dx * dx + dz * dz)

	if length < 1e-4 then return end

	local nx, nz = -dz / length * half_width, dx / length * half_width
	local ux, uz = nx / half_width, nz / half_width
	local y1a, y1b = y0a + height, y0b + height
	tint_mesh.AddQuad(
		mesh,
		ax + nx,
		y0a,
		az + nz,
		bx + nx,
		y0b,
		bz + nz,
		bx + nx,
		y1b,
		bz + nz,
		ax + nx,
		y1a,
		az + nz,
		ux,
		0,
		uz
	)
	tint_mesh.AddQuad(
		mesh,
		bx - nx,
		y0b,
		bz - nz,
		ax - nx,
		y0a,
		az - nz,
		ax - nx,
		y1a,
		az - nz,
		bx - nx,
		y1b,
		bz - nz,
		-ux,
		0,
		-uz
	)
	tint_mesh.AddQuad(
		mesh,
		ax + nx,
		y1a,
		az + nz,
		bx + nx,
		y1b,
		bz + nz,
		bx - nx,
		y1b,
		bz - nz,
		ax - nx,
		y1a,
		az - nz,
		0,
		1,
		0
	)
end

function tint_mesh.AddTaperedBox(mesh, cx, cz, y0, y1, bx, bz, tx, tz)
	local slope_x, slope_z = (bx - tx) / (y1 - y0), (bz - tz) / (y1 - y0)
	local lx, lz = 1 / math.sqrt(1 + slope_x * slope_x), 1 / math.sqrt(1 + slope_z * slope_z)
	tint_mesh.AddQuad(
		mesh,
		cx - bx,
		y0,
		cz + bz,
		cx + bx,
		y0,
		cz + bz,
		cx + tx,
		y1,
		cz + tz,
		cx - tx,
		y1,
		cz + tz,
		0,
		slope_z * lz,
		lz
	)
	tint_mesh.AddQuad(
		mesh,
		cx + bx,
		y0,
		cz - bz,
		cx - bx,
		y0,
		cz - bz,
		cx - tx,
		y1,
		cz - tz,
		cx + tx,
		y1,
		cz - tz,
		0,
		slope_z * lz,
		-lz
	)
	tint_mesh.AddQuad(
		mesh,
		cx + bx,
		y0,
		cz + bz,
		cx + bx,
		y0,
		cz - bz,
		cx + tx,
		y1,
		cz - tz,
		cx + tx,
		y1,
		cz + tz,
		lx,
		slope_x * lx,
		0
	)
	tint_mesh.AddQuad(
		mesh,
		cx - bx,
		y0,
		cz - bz,
		cx - bx,
		y0,
		cz + bz,
		cx - tx,
		y1,
		cz + tz,
		cx - tx,
		y1,
		cz - tz,
		-lx,
		slope_x * lx,
		0
	)
	tint_mesh.AddQuad(
		mesh,
		cx - tx,
		y1,
		cz + tz,
		cx + tx,
		y1,
		cz + tz,
		cx + tx,
		y1,
		cz - tz,
		cx - tx,
		y1,
		cz - tz,
		0,
		1,
		0
	)
end

return tint_mesh
