local ffi = require("ffi")
local bit = require("bit")
local packed_mesh = import("goluwa/render3d/packed_mesh.lua")
local vertex_math = import("goluwa/render3d/vertex_math.lua")
local blob = import("goluwa/codecs/internal/blob.lua")
local resource = import("goluwa/source_engine/source2/resource.lua")
local vbib = import("goluwa/source_engine/source2/vbib.lua")
local animation = import("goluwa/source_engine/source2/animation.lua")
local units = import("goluwa/source_engine/units.lua")
local SCALE = units.meters
local mesh_pack = {}
local VertexType = vertex_math.VertexType
local u16_array_t = ffi.typeof("uint16_t[?]")
local u32_array_t = ffi.typeof("uint32_t[?]")
local float_array_t = ffi.typeof("float[?]")
local u16_ptr_t = ffi.typeof("const uint16_t *")
local u32_ptr_t = ffi.typeof("const uint32_t *")
local F = vbib.FORMAT

function mesh_pack.PackDrawCall(builder, buffers, draw_call, name, skin)
	local vb = buffers.vertex[draw_call.m_vertexBuffers[1].m_hBuffer]
	local ib = buffers.index[draw_call.m_indexBuffer.m_hBuffer]
	local base = draw_call.m_nBaseVertex
	local vertex_count = draw_call.m_nVertexCount
	local index_count = draw_call.m_nIndexCount
	local position = assert(vbib.GetField(vb, "POSITION"), "no POSITION")
	local normal = vbib.GetField(vb, "NORMAL")
	local texcoord = vbib.GetField(vb, "TEXCOORD", 0)
	local color = vbib.GetField(vb, "COLOR")
	local blend_indices = skin and vbib.GetField(vb, "BLENDINDICES")
	local blend_weights = skin and vbib.GetField(vb, "BLENDWEIGHT")

	if
		color and
		color.format ~= F.R8G8B8A8_UNORM and
		color.format ~= F.R32G32B32A32_FLOAT
	then
		color = nil
	end

	local vertices = VertexType(vertex_count)
	local blend = color and float_array_t(vertex_count)
	local min_x, min_y, min_z = math.huge, math.huge, math.huge
	local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

	for i = 0, vertex_count - 1 do
		local v = vertices[i]
		local x, y, z = vbib.Read(vb, position, base + i)
		local nx, ny, nz, tx, ty, tz, ts

		if normal then
			nx, ny, nz, tx, ty, tz, ts = vbib.ReadNormalTangent(vb, normal, base + i)
		end

		if blend_indices and blend_weights then
			local i1, i2, i3, i4 = vbib.Read(vb, blend_indices, base + i)
			local w1, w2, w3, w4 = vbib.Read(vb, blend_weights, base + i)
			local total = w1 + w2 + w3 + w4
			local sx, sy, sz, snx, sny, snz, stx, sty, stz = 0, 0, 0, 0, 0, 0, 0, 0, 0

			for j = 1, 4 do
				local bone = skin[(j == 1 and i1 or j == 2 and i2 or j == 3 and i3 or i4)]
				local weight = (j == 1 and w1 or j == 2 and w2 or j == 3 and w3 or w4) / total

				if bone and weight > 0 then
					local m = bone.m
					sx = sx + weight * (m[1] * x + m[2] * y + m[3] * z + bone.x)
					sy = sy + weight * (m[4] * x + m[5] * y + m[6] * z + bone.y)
					sz = sz + weight * (m[7] * x + m[8] * y + m[9] * z + bone.z)

					if nx then
						snx = snx + weight * (m[1] * nx + m[2] * ny + m[3] * nz)
						sny = sny + weight * (m[4] * nx + m[5] * ny + m[6] * nz)
						snz = snz + weight * (m[7] * nx + m[8] * ny + m[9] * nz)
						stx = stx + weight * (m[1] * tx + m[2] * ty + m[3] * tz)
						sty = sty + weight * (m[4] * tx + m[5] * ty + m[6] * tz)
						stz = stz + weight * (m[7] * tx + m[8] * ty + m[9] * tz)
					end
				end
			end

			x, y, z = sx, sy, sz

			if nx then
				local nl = math.sqrt(snx * snx + sny * sny + snz * snz)
				local tl = math.sqrt(stx * stx + sty * sty + stz * stz)
				nx, ny, nz = snx / nl, sny / nl, snz / nl
				tx, ty, tz = stx / tl, sty / tl, stz / tl
			end
		end

		local px, py, pz = -y * SCALE, z * SCALE, -x * SCALE
		v.position[0], v.position[1], v.position[2] = px, py, pz

		if px < min_x then min_x = px end

		if py < min_y then min_y = py end

		if pz < min_z then min_z = pz end

		if px > max_x then max_x = px end

		if py > max_y then max_y = py end

		if pz > max_z then max_z = pz end

		if normal then
			v.normal[0], v.normal[1], v.normal[2] = -ny, nz, -nx
			v.tangent[0], v.tangent[1], v.tangent[2], v.tangent[3] = -ty, tz, -tx, ts
		else
			v.normal[0], v.normal[1], v.normal[2] = 0, 1, 0
			v.tangent[0], v.tangent[1], v.tangent[2], v.tangent[3] = 1, 0, 0, 1
		end

		if texcoord then
			local u, w = vbib.Read(vb, texcoord, base + i)
			v.uv[0], v.uv[1] = u, w
		end

		v.texture_blend = 0

		if color then blend[i] = (vbib.Read(vb, color, base + i)) end

		v.vertex_color[0], v.vertex_color[1], v.vertex_color[2], v.vertex_color[3] = 1, 1, 1, 1
	end

	local index_size = vertex_count > 65535 and 4 or 2
	local indices = (index_size == 4 and u32_array_t or u16_array_t)(index_count)
	local start = draw_call.m_nStartIndex
	local source = ib.element_size == 2 and
		ffi.cast(u16_ptr_t, ib.data) or
		ffi.cast(u32_ptr_t, ib.data)

	for i = 0, index_count - 3, 3 do
		indices[i] = source[start + i]
		indices[i + 1] = source[start + i + 2]
		indices[i + 2] = source[start + i + 1]
	end

	for i = 0, index_count - 1 do
		assert(indices[i] < vertex_count, name .. ": index out of range")
	end

	assert(min_x == min_x and max_x - min_x < 1e6, name .. ": invalid positions")
	local entry = packed_mesh.PackArrays(builder, vertices, vertex_count, indices, index_count, index_size)
	entry.material = draw_call.m_material
	entry.bounds = {min_x, min_y, min_z, max_x, max_y, max_z}

	if blend then entry.blend_offset = builder:Add(blend, vertex_count * 4) end

	return entry
end

function mesh_pack.PackMeshes(builder, entries, data, buffers, name, skin)
	for _, object in ipairs(data.m_sceneObjects) do
		for _, draw_call in ipairs(object.m_drawCalls) do
			if
				draw_call.m_nPrimitiveType == "RENDER_PRIM_TRIANGLES" and
				draw_call.m_nIndexCount > 0
			then
				entries[#entries + 1] = mesh_pack.PackDrawCall(builder, buffers, draw_call, name, skin)
			end
		end
	end
end

function mesh_pack.PackModel(input)
	local builder = blob.New()
	local entries = {}
	local meta = {entries = entries}

	for _, mesh in ipairs(input.meshes) do
		local res = resource.Parse(mesh)
		mesh_pack.PackMeshes(
			builder,
			entries,
			resource.ReadKV3(res),
			vbib.Parse(res.data, res.blocks.VBIB.offset),
			input.path
		)
	end

	if input.model then
		local res = resource.Parse(input.model)
		local control = res.blocks.CTRL and resource.ReadKV3(res, "CTRL")

		if control and control.embedded_physics then
			meta.physics_block = control.embedded_physics.phys_data_block
		end

		local model_data, skin

		if res.blocks.ANIM and res.blocks.AGRP and res.blocks.ASEQ then
			model_data = resource.ReadKV3(res)
			local ok, result = pcall(animation.GetDefaultSkin, res, model_data)

			if ok then skin = result end
		end

		for _, embedded in ipairs(control and control.embedded_meshes or {}) do
			if
				bit.band(
					input.masks[input.external + embedded.mesh_index + 1] or
						(
							embedded.mesh_index == 0 and
							1 or
							0
						),
					1
				) ~= 0
			then
				mesh_pack.PackMeshes(
					builder,
					entries,
					resource.ReadKV3(res, embedded.data_block),
					vbib.Parse(res.data, res.list[embedded.vbib_block].offset),
					input.path,
					skin and animation.GetMeshSkin(model_data, skin, embedded.mesh_index)
				)
			end
		end
	end

	return meta, builder:Finish()
end

return mesh_pack
