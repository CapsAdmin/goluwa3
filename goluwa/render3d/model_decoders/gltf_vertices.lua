local ffi = require("ffi")
local AABB = import("goluwa/structs/aabb.lua")
local vertex_math = import("goluwa/render3d/vertex_math.lua")
local gltf_vertices = {}

function gltf_vertices.Build(primitive, flip_v)
	local position = primitive.attributes.POSITION
	local normal = primitive.attributes.NORMAL
	local texcoord = primitive.attributes.TEXCOORD_0
	local tangent = primitive.attributes.TANGENT

	if not position then return nil, "POSITION attribute is required" end

	local vertex_count = position.count
	local vertices = vertex_math.VertexType(vertex_count)
	local min_x, min_y, min_z = math.huge, math.huge, math.huge
	local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

	for i = 0, vertex_count - 1 do
		local vertex = vertices[i]
		local px, py, pz = position.data[i * 3 + 0], position.data[i * 3 + 1], position.data[i * 3 + 2]
		vertex.position[0], vertex.position[1], vertex.position[2] = px, py, pz
		min_x, min_y, min_z = math.min(min_x, px), math.min(min_y, py), math.min(min_z, pz)
		max_x, max_y, max_z = math.max(max_x, px), math.max(max_y, py), math.max(max_z, pz)

		if normal then
			vertex.normal[0], vertex.normal[1], vertex.normal[2] = normal.data[i * 3 + 0], normal.data[i * 3 + 1], normal.data[i * 3 + 2]
		else
			vertex.normal[0], vertex.normal[1], vertex.normal[2] = 0, 0, 1
		end

		if texcoord then
			vertex.uv[0], vertex.uv[1] = texcoord.data[i * 2 + 0], texcoord.data[i * 2 + 1]
		end

		if tangent then
			vertex.tangent[0], vertex.tangent[1], vertex.tangent[2], vertex.tangent[3] = tangent.data[i * 4 + 0],
			tangent.data[i * 4 + 1],
			tangent.data[i * 4 + 2],
			tangent.data[i * 4 + 3]
		else
			vertex.tangent[0], vertex.tangent[1], vertex.tangent[2], vertex.tangent[3] = 1, 0, 0, 1
		end

		vertex.texture_blend = 0
		vertex.vertex_color[0], vertex.vertex_color[1], vertex.vertex_color[2], vertex.vertex_color[3] = 1, 1, 1, 1
	end

	if not tangent and texcoord then
		local tan_u = ffi.new("double[?]", vertex_count * 3)
		local tan_v = ffi.new("double[?]", vertex_count * 3)
		local indices = primitive.indices
		local index_count = indices and indices.count or vertex_count

		for i = 0, index_count - 3, 3 do
			local ia = indices and indices.data[i] or i
			local ib = indices and indices.data[i + 1] or i + 1
			local ic = indices and indices.data[i + 2] or i + 2
			local a, b, c = vertices[ia], vertices[ib], vertices[ic]
			local x1, y1, z1 = b.position[0] - a.position[0], b.position[1] - a.position[1], b.position[2] - a.position[2]
			local x2, y2, z2 = c.position[0] - a.position[0], c.position[1] - a.position[1], c.position[2] - a.position[2]
			local s1, t1 = b.uv[0] - a.uv[0], b.uv[1] - a.uv[1]
			local s2, t2 = c.uv[0] - a.uv[0], c.uv[1] - a.uv[1]
			local denom = s1 * t2 - s2 * t1

			if math.abs(denom) > 1e-12 then
				local r = 1 / denom
				local ux, uy, uz = (t2 * x1 - t1 * x2) * r, (t2 * y1 - t1 * y2) * r, (t2 * z1 - t1 * z2) * r
				local vx, vy, vz = (s1 * x2 - s2 * x1) * r, (s1 * y2 - s2 * y1) * r, (s1 * z2 - s2 * z1) * r

				for k = 0, 2 do
					local o = (k == 0 and ia or k == 1 and ib or ic) * 3
					tan_u[o], tan_u[o + 1], tan_u[o + 2] = tan_u[o] + ux, tan_u[o + 1] + uy, tan_u[o + 2] + uz
					tan_v[o], tan_v[o + 1], tan_v[o + 2] = tan_v[o] + vx, tan_v[o + 1] + vy, tan_v[o + 2] + vz
				end
			end
		end

		for i = 0, vertex_count - 1 do
			local o = i * 3
			local n = vertices[i].normal
			local nx, ny, nz = n[0], n[1], n[2]
			local ux, uy, uz = tan_u[o], tan_u[o + 1], tan_u[o + 2]
			local d = nx * ux + ny * uy + nz * uz
			ux, uy, uz = ux - nx * d, uy - ny * d, uz - nz * d
			local length = math.sqrt(ux * ux + uy * uy + uz * uz)

			if length > 1e-9 then
				ux, uy, uz = ux / length, uy / length, uz / length
			elseif math.abs(ny) < 0.999 then
				local inverse = 1 / math.sqrt(nz * nz + nx * nx)
				ux, uy, uz = nz * inverse, 0, -nx * inverse
			else
				local inverse = 1 / math.sqrt(nz * nz + ny * ny)
				ux, uy, uz = 0, -nz * inverse, ny * inverse
			end

			local bx, by, bz = ny * uz - nz * uy, nz * ux - nx * uz, nx * uy - ny * ux
			local handedness = (bx * tan_v[o] + by * tan_v[o + 1] + bz * tan_v[o + 2]) < 0 and 1 or -1
			vertices[i].tangent[0], vertices[i].tangent[1], vertices[i].tangent[2], vertices[i].tangent[3] = ux, uy, uz, handedness
		end
	end

	if texcoord and flip_v then
		for i = 0, vertex_count - 1 do
			vertices[i].uv[1] = 1 - vertices[i].uv[1]
		end
	end

	return vertices, vertex_count, AABB(min_x, min_y, min_z, max_x, max_y, max_z)
end

return gltf_vertices
