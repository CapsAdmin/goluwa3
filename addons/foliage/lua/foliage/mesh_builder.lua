local ffi = require("ffi")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local vertex_math = import("goluwa/render3d/vertex_math.lua")
local vegetation_pivots = import("goluwa/render3d/vegetation_pivots.lua")
local VertexType = vertex_math.VertexType
local Index32Array = ffi.typeof("uint32_t[?]")
local Index16Array = ffi.typeof("uint16_t[?]")
local sqrt, cos, sin, pi = math.sqrt, math.cos, math.sin, math.pi
local MeshBuilder = {}
MeshBuilder.__index = MeshBuilder

function MeshBuilder.New()
	return setmetatable(
		{
			vertices = VertexType(1024),
			vertex_capacity = 1024,
			vertex_count = 0,
			indices = Index32Array(3072),
			index_capacity = 3072,
			index_count = 0,
			chain_vertices = 0,
			r = 0,
			g = 0,
			b = 1,
		},
		MeshBuilder
	)
end

function MeshBuilder:SetColor(flutter, phase, stiffness)
	self.r, self.g, self.b = flutter, phase, stiffness
end

function MeshBuilder:SetChain(px, py, pz, mx, my, mz, tx, ty, tz)
	self.chain = {px, py, pz, mx, my, mz, tx, ty, tz}
end

function MeshBuilder:GetChain()
	return self.chain
end

function MeshBuilder:RestoreChain(chain)
	self.chain = chain
end

function MeshBuilder:ClearChain()
	self.chain = nil
end

function MeshBuilder:Vertex(px, py, pz, nx, ny, nz, u, v)
	local count = self.vertex_count

	if count == self.vertex_capacity then
		local capacity = count * 2
		local vertices = VertexType(capacity)
		ffi.copy(vertices, self.vertices, ffi.sizeof(VertexType, count))
		self.vertices = vertices
		self.vertex_capacity = capacity
	end

	local length = sqrt(nx * nx + ny * ny + nz * nz)

	if length > 0 then nx, ny, nz = nx / length, ny / length, nz / length end

	local vertex = self.vertices[count]
	local position, normal, uv, color = vertex.position, vertex.normal, vertex.uv, vertex.vertex_color
	local chain = self.chain
	local pivot, mid, tip = vertex.pivot, vertex.chain_mid, vertex.chain_tip

	if chain then
		self.chain_vertices = self.chain_vertices + 1
		pivot[0], pivot[1], pivot[2], pivot[3] = chain[1], chain[2], chain[3], 1
		mid[0], mid[1], mid[2] = chain[4], chain[5], chain[6]
		tip[0], tip[1], tip[2] = chain[7], chain[8], chain[9]
	else
		pivot[0], pivot[1], pivot[2], pivot[3] = 0, 0, 0, 0
		mid[0], mid[1], mid[2] = 0, 0, 0
		tip[0], tip[1], tip[2] = 0, 0, 0
	end

	position[0], position[1], position[2] = px, py, pz
	normal[0], normal[1], normal[2] = nx, ny, nz
	uv[0], uv[1] = u, v
	color[0], color[1], color[2], color[3] = self.r, self.g, self.b, 1
	vertex.texture_blend = 0
	self.vertex_count = count + 1
	return count
end

function MeshBuilder:Triangle(a, b, c)
	local count = self.index_count

	if count + 3 > self.index_capacity then
		local capacity = self.index_capacity * 2
		local indices = Index32Array(capacity)
		ffi.copy(indices, self.indices, ffi.sizeof(Index32Array, count))
		self.indices = indices
		self.index_capacity = capacity
	end

	local indices = self.indices
	indices[count], indices[count + 1], indices[count + 2] = a, c, b
	self.index_count = count + 3
end

function MeshBuilder:Quad(a, b, c, d)
	self:Triangle(a, b, c)
	self:Triangle(a, c, d)
end

function MeshBuilder:GetVertexCount()
	return self.vertex_count
end

function MeshBuilder:IsEmpty()
	return self.index_count == 0
end

function MeshBuilder:GetPosition(index)
	local p = self.vertices[index].position
	return p[0], p[1], p[2]
end

function MeshBuilder:SetPosition(index, x, y, z)
	local p = self.vertices[index].position
	p[0], p[1], p[2] = x, y, z
end

function MeshBuilder:SetNormal(index, x, y, z)
	local length = sqrt(x * x + y * y + z * z)
	local n = self.vertices[index].normal
	n[0], n[1], n[2] = x / length, y / length, z / length
end

function MeshBuilder:GetNormal(index)
	local n = self.vertices[index].normal
	return n[0], n[1], n[2]
end

function MeshBuilder:BuildNormals(first_vertex, first_index)
	first_vertex = first_vertex or 0
	first_index = first_index or 0
	local vertices, indices = self.vertices, self.indices

	for i = first_vertex, self.vertex_count - 1 do
		local n = vertices[i].normal
		n[0], n[1], n[2] = 0, 0, 0
	end

	for i = first_index, self.index_count - 3, 3 do
		local a, b, c = indices[i], indices[i + 1], indices[i + 2]
		local pa, pb, pc = vertices[a].position, vertices[b].position, vertices[c].position
		local x1, y1, z1 = pb[0] - pa[0], pb[1] - pa[1], pb[2] - pa[2]
		local x2, y2, z2 = pc[0] - pa[0], pc[1] - pa[1], pc[2] - pa[2]
		local nx, ny, nz = z1 * y2 - y1 * z2, x1 * z2 - z1 * x2, y1 * x2 - x1 * y2

		for _, index in ipairs{a, b, c} do
			local n = vertices[index].normal
			n[0], n[1], n[2] = n[0] + nx, n[1] + ny, n[2] + nz
		end
	end

	for i = first_vertex, self.vertex_count - 1 do
		local n = vertices[i].normal
		local length = sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2])

		if length > 0 then
			n[0], n[1], n[2] = n[0] / length, n[1] / length, n[2] / length
		end
	end
end

do
	local function normalize(x, y, z)
		local length = sqrt(x * x + y * y + z * z)

		if length == 0 then return 0, 1, 0 end

		return x / length, y / length, z / length
	end

	local function cross(ax, ay, az, bx, by, bz)
		return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
	end

	function MeshBuilder:Tube(points, options)
		local sides = options.sides
		local u_repeat = options.u_repeat or 1
		local v_length = options.v_length or 1
		local v = options.v_offset or 0
		local count = #points
		local p1, p2 = points[1], points[2]
		local tx, ty, tz = normalize(p2[1] - p1[1], p2[2] - p1[2], p2[3] - p1[3])
		local ax, ay, az = 0, 0, 1

		if math.abs(tz) > 0.9 then ax, ay, az = 1, 0, 0 end

		local rx, ry, rz = normalize(cross(tx, ty, tz, ax, ay, az))
		local ring_first = {}

		for i = 1, count do
			local point = points[i]
			local next_point = points[math.min(i + 1, count)]
			local prev_point = points[math.max(i - 1, 1)]
			local dx, dy, dz = normalize(
				next_point[1] - prev_point[1],
				next_point[2] - prev_point[2],
				next_point[3] - prev_point[3]
			)
			local dot = rx * dx + ry * dy + rz * dz
			rx, ry, rz = normalize(rx - dx * dot, ry - dy * dot, rz - dz * dot)
			local ux, uy, uz = cross(dx, dy, dz, rx, ry, rz)

			if i > 1 then
				local px, py, pz = prev_point[1] - point[1], prev_point[2] - point[2], prev_point[3] - point[3]
				v = v + sqrt(px * px + py * py + pz * pz) / v_length
			end

			self:SetColor(point[5] or 0, point[6] or 0, point[7] or 1)
			ring_first[i] = self.vertex_count

			for side = 0, sides do
				local angle = side / sides * pi * 2
				local c, s = cos(angle), sin(angle)
				local nx, ny, nz = rx * c + ux * s, ry * c + uy * s, rz * c + uz * s
				local radius = point[4]
				self:Vertex(
					point[1] + nx * radius,
					point[2] + ny * radius,
					point[3] + nz * radius,
					nx,
					ny,
					nz,
					side / sides * u_repeat,
					v
				)
			end
		end

		for i = 1, count - 1 do
			local a, b = ring_first[i], ring_first[i + 1]

			for side = 0, sides - 1 do
				self:Quad(a + side, a + side + 1, b + side + 1, b + side)
			end
		end

		if options.cap then
			local last = points[count]
			local prev = points[count - 1]
			local dx, dy, dz = normalize(last[1] - prev[1], last[2] - prev[2], last[3] - prev[3])
			local tip = self:Vertex(
				last[1] + dx * last[4],
				last[2] + dy * last[4],
				last[3] + dz * last[4],
				dx,
				dy,
				dz,
				0.5 * u_repeat,
				v + last[4] / v_length
			)
			local a = ring_first[count]

			for side = 0, sides - 1 do
				self:Triangle(a + side, a + side + 1, tip)
			end
		end

		return v
	end
end

function MeshBuilder:Card(cx, cy, cz, rx, ry, rz, ux, uy, uz, nx, ny, nz, uv)
	local a = self:Vertex(cx - rx - ux, cy - ry - uy, cz - rz - uz, nx, ny, nz, uv[1], uv[2])
	local b = self:Vertex(cx + rx - ux, cy + ry - uy, cz + rz - uz, nx, ny, nz, uv[3], uv[2])
	local c = self:Vertex(cx + rx + ux, cy + ry + uy, cz + rz + uz, nx, ny, nz, uv[3], uv[4])
	local d = self:Vertex(cx - rx + ux, cy - ry + uy, cz - rz + uz, nx, ny, nz, uv[1], uv[4])
	self:Quad(a, b, c, d)
	return a
end

local function transform_point(point, ax, ay, az, o)
	local x, y, z = point[0], point[1], point[2]
	point[0] = x * ax[1] + y * ay[1] + z * az[1] + o[1]
	point[1] = x * ax[2] + y * ay[2] + z * az[2] + o[2]
	point[2] = x * ax[3] + y * ay[3] + z * az[3] + o[3]
end

function MeshBuilder:Transform(first_vertex, ax, ay, az, o)
	local vertices = self.vertices

	for i = first_vertex, self.vertex_count - 1 do
		local p, n = vertices[i].position, vertices[i].normal
		local x, y, z = p[0], p[1], p[2]
		p[0] = x * ax[1] + y * ay[1] + z * az[1] + o[1]
		p[1] = x * ax[2] + y * ay[2] + z * az[2] + o[2]
		p[2] = x * ax[3] + y * ay[3] + z * az[3] + o[3]
		x, y, z = n[0], n[1], n[2]
		local nx = x * ax[1] + y * ay[1] + z * az[1]
		local ny = x * ax[2] + y * ay[2] + z * az[2]
		local nz = x * ax[3] + y * ay[3] + z * az[3]
		local length = sqrt(nx * nx + ny * ny + nz * nz)
		n[0], n[1], n[2] = nx / length, ny / length, nz / length

		if vertices[i].pivot[3] > 0.5 then
			transform_point(vertices[i].pivot, ax, ay, az, o)
			transform_point(vertices[i].chain_mid, ax, ay, az, o)
			transform_point(vertices[i].chain_tip, ax, ay, az, o)
		end
	end
end

function MeshBuilder:Build(options)
	assert(self.index_count > 0, "the mesh is empty")
	options = options or {}
	local vertex_count, index_count = self.vertex_count, self.index_count
	local vertices = VertexType(vertex_count)
	ffi.copy(vertices, self.vertices, ffi.sizeof(VertexType, vertex_count))
	local indices

	if vertex_count > 65535 then
		indices = Index32Array(index_count)
		ffi.copy(indices, self.indices, ffi.sizeof(Index32Array, index_count))
	else
		indices = Index16Array(index_count)

		for i = 0, index_count - 1 do
			indices[i] = self.indices[i]
		end
	end

	vertex_math.BuildTangents(vertices, vertex_count, indices, index_count)
	if self.chain_vertices < vertex_count then
		vegetation_pivots.ComputeArray(vertices, vertex_count, indices, index_count, true)
	end

	local polygon = Polygon3D.New()
	polygon:UploadVertexArray(vertices, vertex_count, indices, index_count, true)
	polygon:SetBendHeight(options.bend_height or 0)
	polygon:SetRootChain(options.root_chain)
	polygon:SetLODLevel(options.lod_level or 0)
	polygon:SetLODDistance(options.lod_distance or 0)

	if options.name then polygon:SetName(options.name) end

	return polygon
end

return MeshBuilder
