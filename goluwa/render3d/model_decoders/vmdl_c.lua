local ffi = require("ffi")
local bit = require("bit")
local vfs = import("goluwa/vfs.lua")
local tasks = import("goluwa/tasks.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local AABB = import("goluwa/structs/aabb.lua")
local resource = import("goluwa/source_engine/source2/resource.lua")
local vbib = import("goluwa/source_engine/source2/vbib.lua")
local s2_material = import("goluwa/source_engine/source2/material.lua")
local units = import("goluwa/source_engine/units.lua")
local SCALE = units.meters
local vmdl_c = {}
local VertexType = Polygon3D.VertexType
local u16_array_t = ffi.typeof("uint16_t[?]")
local u32_array_t = ffi.typeof("uint32_t[?]")
local u16_ptr_t = ffi.typeof("const uint16_t *")
local u32_ptr_t = ffi.typeof("const uint32_t *")
local f32_ptr_t = ffi.typeof("const float *")
local F = vbib.FORMAT

function vmdl_c.BuildPolygon(buffers, draw_call, name)
	local vb = buffers.vertex[draw_call.m_vertexBuffers[1].m_hBuffer]
	local ib = buffers.index[draw_call.m_indexBuffer.m_hBuffer]
	local base = draw_call.m_nBaseVertex
	local vertex_count = draw_call.m_nVertexCount
	local index_count = draw_call.m_nIndexCount
	local position = assert(vbib.GetField(vb, "POSITION"), "no POSITION")
	local normal = vbib.GetField(vb, "NORMAL")
	local texcoord = vbib.GetField(vb, "TEXCOORD", 0)
	local vertices = VertexType(vertex_count)
	local min_x, min_y, min_z = math.huge, math.huge, math.huge
	local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

	for i = 0, vertex_count - 1 do
		local v = vertices[i]
		local x, y, z = vbib.Read(vb, position, base + i)
		local px, py, pz = -y * SCALE, z * SCALE, -x * SCALE
		v.position[0], v.position[1], v.position[2] = px, py, pz

		if px < min_x then min_x = px end

		if py < min_y then min_y = py end

		if pz < min_z then min_z = pz end

		if px > max_x then max_x = px end

		if py > max_y then max_y = py end

		if pz > max_z then max_z = pz end

		if normal then
			local nx, ny, nz, tx, ty, tz, ts = vbib.ReadNormalTangent(vb, normal, base + i)
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
		v.vertex_color[0], v.vertex_color[1], v.vertex_color[2], v.vertex_color[3] = 1, 1, 1, 1
	end

	local indices

	if vertex_count > 65535 then
		indices = u32_array_t(index_count)
	else
		indices = u16_array_t(index_count)
	end

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
	local polygon = Polygon3D.New()
	polygon:UploadVertexArray(
		vertices,
		vertex_count,
		indices,
		index_count,
		true,
		nil,
		AABB(min_x, min_y, min_z, max_x, max_y, max_z)
	)
	polygon:SetName(name)
	return polygon
end

function vmdl_c.EmitMesh(data, buffers, path, mesh_callback)
	for _, object in ipairs(data.m_sceneObjects) do
		for _, draw_call in ipairs(object.m_drawCalls) do
			if
				draw_call.m_nPrimitiveType == "RENDER_PRIM_TRIANGLES" and
				draw_call.m_nIndexCount > 0
			then
				local polygon = vmdl_c.BuildPolygon(buffers, draw_call, path)
				mesh_callback(polygon, s2_material.FromVMAT(draw_call.m_material))

				tasks.Wait()
			end
		end
	end
end

function vmdl_c.LoadMesh(path, mesh_callback)
	local res = resource.Load(vfs, path)
	vmdl_c.EmitMesh(
		resource.ReadKV3(res),
		vbib.Parse(res.data, res.blocks.VBIB.offset),
		path,
		mesh_callback
	)
end

local function decode_vmdl(path, full_path, mesh_callback)
	local res = resource.Load(vfs, full_path)
	local ok, data = pcall(resource.ReadKV3, res)
	local external = 0
	local masks = {}

	if ok then
		masks = data.m_refLODGroupMasks or {}
		external = #data.m_refMeshes
	else
		data = {m_refMeshes = {}}
	end

	for i, mesh in ipairs(data.m_refMeshes) do
		if bit.band(masks[i] or 1, 1) ~= 0 then
			vmdl_c.LoadMesh(mesh .. "_c", mesh_callback)
		end
	end

	local control = res.blocks.CTRL and resource.ReadKV3(res, "CTRL")

	for _, embedded in ipairs(control and control.embedded_meshes or {}) do
		if
			bit.band(masks[external + embedded.mesh_index + 1] or
				(
					embedded.mesh_index == 0 and
					1 or
					0
				), 1) ~= 0
		then
			vmdl_c.EmitMesh(
				resource.ReadKV3(res, embedded.data_block),
				vbib.Parse(res.data, res.list[embedded.vbib_block].offset),
				path,
				mesh_callback
			)
		end
	end
end

model_loader.AddModelDecoder("vmdl_c", decode_vmdl)

model_loader.AddModelDecoder("vmesh_c", function(path, full_path, mesh_callback)
	vmdl_c.LoadMesh(full_path, mesh_callback)
end)

return vmdl_c
