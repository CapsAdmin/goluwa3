local ffi = require("ffi")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local VertexType = Polygon3D.VertexType
local Index16Array = ffi.typeof("uint16_t[?]")
local Index32Array = ffi.typeof("uint32_t[?]")
local VERTEX_SIZE = ffi.sizeof(VertexType(1)[0])
local sqrt = math.sqrt
-- the scene bvh is made on the cpu, from polygons, so what scatter grows near the camera is also made into polygons
-- for it: the instances of one prototype in one unit, each a copy of a simple stand-in for the model, in one polygon
local scatter_proxy = {}

-- the vertices and indices of a mesh that is uploaded, the way the cpu still has them
function scatter_proxy.GetTemplate(mesh)
	local vertex_buffer = mesh.vertex_buffer
	local index_buffer = mesh.index_buffer
	local vertex_count = vertex_buffer:GetVertexCount()
	local index_count = index_buffer:GetIndexCount()
	local vertices = VertexType(vertex_count)
	ffi.copy(vertices, vertex_buffer.data, vertex_count * VERTEX_SIZE)
	local indices = Index32Array(index_count)
	local data = index_buffer:GetData()

	if type(data) == "cdata" then
		local typed = ffi.cast(index_buffer:GetIndexTypeFFI() .. "*", data)

		for i = 0, index_count - 1 do
			indices[i] = typed[i]
		end
	else
		for i = 0, index_count - 1 do
			indices[i] = data[i + 1]
		end
	end

	return {vertices = vertices, vertex_count = vertex_count, indices = indices, index_count = index_count}
end

-- a copy of the template for each of the selected instances. an instance is a matrix of 16 floats, its columns are
-- the axes (with their scale) and the position
function scatter_proxy.Build(template, instances, selected, selected_count)
	local template_vertices = template.vertices
	local template_indices = template.indices
	local tv, ti = template.vertex_count, template.index_count
	local vertex_count = tv * selected_count
	local index_count = ti * selected_count
	local vertices = VertexType(vertex_count)
	local indices = vertex_count > 65535 and Index32Array(index_count) or Index16Array(index_count)

	for n = 0, selected_count - 1 do
		local m = instances + selected[n] * 16
		local c0x, c0y, c0z = m[0], m[1], m[2]
		local c1x, c1y, c1z = m[4], m[5], m[6]
		local c2x, c2y, c2z = m[8], m[9], m[10]
		local px, py, pz = m[12], m[13], m[14]
		-- the axes stand perpendicular, so what a normal is turned by is each axis over its squared length
		local i0 = 1 / (c0x * c0x + c0y * c0y + c0z * c0z)
		local i1 = 1 / (c1x * c1x + c1y * c1y + c1z * c1z)
		local i2 = 1 / (c2x * c2x + c2y * c2y + c2z * c2z)
		local base = n * tv

		for v = 0, tv - 1 do
			local s = template_vertices[v]
			local d = vertices[base + v]
			local x, y, z = s.position[0], s.position[1], s.position[2]
			d.position[0] = c0x * x + c1x * y + c2x * z + px
			d.position[1] = c0y * x + c1y * y + c2y * z + py
			d.position[2] = c0z * x + c1z * y + c2z * z + pz
			local k0, k1, k2 = s.normal[0] * i0, s.normal[1] * i1, s.normal[2] * i2
			local nx = c0x * k0 + c1x * k1 + c2x * k2
			local ny = c0y * k0 + c1y * k1 + c2y * k2
			local nz = c0z * k0 + c1z * k1 + c2z * k2
			local length = sqrt(nx * nx + ny * ny + nz * nz)
			length = length > 0 and 1 / length or 0
			d.normal[0], d.normal[1], d.normal[2] = nx * length, ny * length, nz * length
			local tx, ty, tz = s.tangent[0], s.tangent[1], s.tangent[2]
			local ex = c0x * tx + c1x * ty + c2x * tz
			local ey = c0y * tx + c1y * ty + c2y * tz
			local ez = c0z * tx + c1z * ty + c2z * tz
			length = sqrt(ex * ex + ey * ey + ez * ez)
			length = length > 0 and 1 / length or 0
			d.tangent[0], d.tangent[1], d.tangent[2], d.tangent[3] = ex * length, ey * length, ez * length, s.tangent[3]
			d.uv[0], d.uv[1] = s.uv[0], s.uv[1]
			d.texture_blend = s.texture_blend
		end

		local index_base = n * ti

		for i = 0, ti - 1 do
			indices[index_base + i] = template_indices[i] + base
		end
	end

	return vertices, vertex_count, indices, index_count
end

return scatter_proxy
