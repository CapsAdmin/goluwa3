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
local MAX_INFLUENCES = 3
local MAX_BONES = 1024

function mesh_pack.PackDrawCall(builder, buffers, draw_call, name, bone_map)
	local vb = buffers.vertex[draw_call.m_vertexBuffers[1].m_hBuffer]
	local ib = buffers.index[draw_call.m_indexBuffer.m_hBuffer]
	local base = draw_call.m_nBaseVertex
	local vertex_count = draw_call.m_nVertexCount
	local index_count = draw_call.m_nIndexCount
	local position = assert(vbib.GetField(vb, "POSITION"), "no POSITION")
	local normal = vbib.GetField(vb, "NORMAL")
	local texcoord = vbib.GetField(vb, "TEXCOORD", 0)
	local color = vbib.GetField(vb, "COLOR") or vbib.GetField(vb, "TEXCOORD", 4)
	local blend_indices = bone_map and vbib.GetField(vb, "BLENDINDICES")
	local blend_weights = bone_map and vbib.GetField(vb, "BLENDWEIGHT")
	local bone_ids = blend_indices and blend_weights and ffi.new("uint16_t[?]", vertex_count * 4)
	local bone_weights = bone_ids and float_array_t(vertex_count * 4)

	if
		color and
		color.format ~= F.R8G8B8A8_UNORM and
		color.format ~= F.R32G32B32A32_FLOAT
	then
		color = nil
	end

	local motion = vbib.GetField(vb, "TEXCOORD", 3)
	local pivot = vbib.GetField(vb, "TEXCOORD", 4)
	local foliage = motion and
		pivot and
		motion.format == F.R32G32B32_FLOAT and
		pivot.format == F.R32G32B32_FLOAT
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

		if bone_ids then
			local i1, i2, i3, i4 = vbib.Read(vb, blend_indices, base + i)
			local w1, w2, w3, w4 = vbib.Read(vb, blend_weights, base + i)
			mesh_pack.GetVertexBones(
				bone_map.bones,
				bone_map.new_index,
				i1,
				i2,
				i3,
				i4,
				w1,
				w2,
				w3,
				w4,
				bone_ids,
				bone_weights,
				i * 4
			)
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

		if foliage then
			local frond, branch, seed = vbib.Read(vb, motion, base + i)
			local qx, qy, qz = vbib.Read(vb, pivot, base + i)
			local phase = 0

			if qx ~= 0 or qy ~= 0 or qz ~= 0 then
				phase = (math.sin(qx * 12.9898 + qy * 78.233 + qz * 37.719) * 43758.5453 + seed * 7.3) % 1
			end

			v.vertex_color[0], v.vertex_color[1], v.vertex_color[2], v.vertex_color[3] = frond, phase, 1 - math.max(frond, branch), 1
		else
			v.vertex_color[0], v.vertex_color[1], v.vertex_color[2], v.vertex_color[3] = 1, 1, 1, 1
		end
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
	entry.foliage = foliage or nil
	local tint = draw_call.m_vTintColor

	if tint and (tint[1] < 0.999 or tint[2] < 0.999 or tint[3] < 0.999) then
		entry.tint = {tint[1], tint[2], tint[3]}
	end

	entry.bounds = {min_x, min_y, min_z, max_x, max_y, max_z}

	if bone_ids then
		entry.bone_ids_offset = builder:Add(bone_ids, vertex_count * 8)
		entry.bone_weights_offset = builder:Add(bone_weights, vertex_count * 16)
	end

	if blend then entry.blend_offset = builder:Add(blend, vertex_count * 4) end

	return entry
end

do
	local indices, weights = {}, {}

	-- the MAX_INFLUENCES heaviest bones of a vertex, largest weight first, in indices and weights
	local function select_influences(i1, i2, i3, i4, w1, w2, w3, w4)
		indices[1], indices[2], indices[3], indices[4] = i1, i2, i3, i4
		weights[1], weights[2], weights[3], weights[4] = w1, w2, w3, w4

		for m = 1, MAX_INFLUENCES do
			local best = m

			for n = m + 1, 4 do
				if weights[n] > weights[best] then best = n end
			end

			indices[m], indices[best] = indices[best], indices[m]
			weights[m], weights[best] = weights[best], weights[m]
		end
	end

	function mesh_pack.MarkUsedBones(buffers, draw_call, bones, used)
		local vb = buffers.vertex[draw_call.m_vertexBuffers[1].m_hBuffer]
		local blend_indices = vbib.GetField(vb, "BLENDINDICES")
		local blend_weights = vbib.GetField(vb, "BLENDWEIGHT")

		if not (blend_indices and blend_weights) then return end

		for i = 0, draw_call.m_nVertexCount - 1 do
			local row = draw_call.m_nBaseVertex + i
			local i1, i2, i3, i4 = vbib.Read(vb, blend_indices, row)
			local w1, w2, w3, w4 = vbib.Read(vb, blend_weights, row)
			select_influences(i1, i2, i3, i4, w1, w2, w3, w4)

			for m = 1, MAX_INFLUENCES do
				if weights[m] > 0 then used[bones[indices[m]]] = true end
			end
		end
	end

	function mesh_pack.GetVertexBones(bones, new_index, i1, i2, i3, i4, w1, w2, w3, w4, out_ids, out_weights, offset)
		select_influences(i1, i2, i3, i4, w1, w2, w3, w4)
		local total = weights[1] + weights[2] + weights[3]

		for m = 1, MAX_INFLUENCES do
			local used = weights[m] > 0
			out_ids[offset + m - 1] = used and new_index[bones[indices[m]]] or 0
			out_weights[offset + m - 1] = used and weights[m] / total or 0
		end

		out_ids[offset + 3] = 0
		out_weights[offset + 3] = 0
	end
end

function mesh_pack.PackMeshes(builder, entries, data, buffers, name, bone_map)
	for _, object in ipairs(data.m_sceneObjects) do
		for _, draw_call in ipairs(object.m_drawCalls) do
			if
				draw_call.m_nPrimitiveType == "RENDER_PRIM_TRIANGLES" and
				draw_call.m_nIndexCount > 0
			then
				entries[#entries + 1] = mesh_pack.PackDrawCall(builder, buffers, draw_call, name, bone_map)
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

		local model_data

		if res.blocks.ANIM and res.blocks.AGRP and res.blocks.ASEQ and resource.IsKV3(res) then
			model_data = resource.ReadKV3(res)
		end

		local meshes = {}

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
				meshes[#meshes + 1] = {
					data = resource.ReadKV3(res, embedded.data_block),
					buffers = vbib.Parse(res.data, res.list[embedded.vbib_block].offset),
					bones = model_data and animation.GetMeshBones(model_data, embedded.mesh_index),
				}
			end
		end

		local new_index

		if model_data then
			local fe = res.blocks.PHYS and resource.ReadKV3(res, "PHYS").m_pFeModel
			local cloth = fe and fe.m_nNodeCount > 0 and animation.ReadCloth(model_data, fe)
			local bones = animation.ReadBones(model_data, cloth and cloth.parents)
			local used = {}

			for _, mesh in ipairs(meshes) do
				for _, object in ipairs(mesh.data.m_sceneObjects) do
					for _, draw_call in ipairs(object.m_drawCalls) do
						mesh_pack.MarkUsedBones(mesh.buffers, draw_call, mesh.bones, used)
					end
				end
			end

			if next(used) then
				for bone in pairs(cloth and cloth.target_bones or {}) do
					used[bone] = true
				end

				for bone, name in ipairs(model_data.m_modelSkeleton.m_boneName) do
					if name:sub(1, 1) ~= "$" then used[bone - 1] = true end
				end

				local kept
				kept, new_index = animation.GetKeptBones(bones, used)
				assert(#kept <= MAX_BONES, input.path .. ": more than " .. MAX_BONES .. " skinned bones")
				local names, parents, bind_local, inverse_bind = animation.GetBindData(bones, kept, new_index)
				meta.skeleton = {
					names = names,
					parents = parents,
					kept = kept,
					cloth_parents = cloth and cloth.parents,
					clips = animation.GetClips(res),
					bind_offset = builder:Add(bind_local),
					inverse_bind_offset = builder:Add(inverse_bind),
				}

				if cloth then
					local packed = animation.PackCloth(cloth, new_index)
					meta.skeleton.cloth = {
						count = packed.count,
						target_count = packed.target_count,
						rod_count = packed.rod_count,
						bend_count = packed.bend_count,
						capsule_count = packed.capsule_count,
						offsets = {},
					}

					for name, array in pairs(packed.arrays) do
						meta.skeleton.cloth.offsets[name] = builder:Add(array)
					end
				end
			end
		end

		for _, mesh in ipairs(meshes) do
			local bone_map = new_index and {bones = mesh.bones, new_index = new_index}
			mesh_pack.PackMeshes(builder, entries, mesh.data, mesh.buffers, input.path, bone_map)
		end
	end

	return meta, builder:Finish()
end

return mesh_pack
