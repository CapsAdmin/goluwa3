local ffi = require("ffi")
local bit = require("bit")
local vfs = import("goluwa/vfs.lua")
local tasks = import("goluwa/tasks.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local packed_mesh = import("goluwa/render3d/packed_mesh.lua")
local AABB = import("goluwa/structs/aabb.lua")
local resource = import("goluwa/source_engine/source2/resource.lua")
local vphys = import("goluwa/source_engine/source2/vphys.lua")
local s2_material = import("goluwa/source_engine/source2/material.lua")
local f32_ptr_t = ffi.typeof("const float *")
local DECAL_LIFT = 0.03
local job = [=[
	local input = ...
	return import("goluwa/source_engine/source2/mesh_pack.lua").PackModel(input)
]=]

local function finish(path, input, meta, blob_table, mesh_callback, physics_callback)
	local physics_refs = input.physics_refs or {}

	if meta.physics_block ~= nil or #physics_refs > 0 then
		physics_callback(
			setmetatable(
				{},
				{
					__index = function(physics, key)
						setmetatable(physics, nil)
						physics.children = {}
						local body = vphys.NewBody()

						if meta.physics_block ~= nil then
							local res = resource.Parse(input.model)
							local ok, block_data = pcall(resource.ReadKV3, res, meta.physics_block)

							if ok then vphys.Append(physics.children, block_data, body) end
						end

						for _, ref in ipairs(physics_refs) do
							vphys.Append(physics.children, resource.ReadKV3(resource.Load(vfs, ref .. "_c")), body)
						end

						if body.weight > 0 then physics.body = vphys.GetBodyProperties(body) end

						return physics[key]
					end,
				}
			)
		)
	end

	for _, entry in ipairs(meta.entries) do
		s2_material.Prefetch(entry.material)
	end

	for _, entry in ipairs(meta.entries) do
		local vertices, indices = packed_mesh.Unpack(entry, blob_table)

		if entry.blend_offset and s2_material.GetInfo(entry.material).blend then
			local blend = ffi.cast(f32_ptr_t, blob_table.ptr + entry.blend_offset)

			for i = 0, entry.vertex_count - 1 do
				vertices[i].texture_blend = blend[i]
			end
		end

		local bounds = entry.bounds

		if s2_material.GetInfo(entry.material).decal then
			for i = 0, entry.vertex_count - 1 do
				local v = vertices[i]
				v.position[0] = v.position[0] + v.normal[0] * DECAL_LIFT
				v.position[1] = v.position[1] + v.normal[1] * DECAL_LIFT
				v.position[2] = v.position[2] + v.normal[2] * DECAL_LIFT
			end

			bounds = {
				bounds[1] - DECAL_LIFT,
				bounds[2] - DECAL_LIFT,
				bounds[3] - DECAL_LIFT,
				bounds[4] + DECAL_LIFT,
				bounds[5] + DECAL_LIFT,
				bounds[6] + DECAL_LIFT,
			}
		end

		local polygon = Polygon3D.New()
		polygon:UploadVertexArray(
			vertices,
			entry.vertex_count,
			indices,
			entry.index_count,
			true,
			nil,
			AABB(unpack(bounds))
		)
		polygon:SetName(path)
		local material = s2_material.FromVMAT(entry.material)

		if entry.tint then material = material:GetTinted(entry.tint) end

		if entry.foliage then polygon:SetBendHeight(bounds[5]) end

		mesh_callback(polygon, material)
		tasks.Wait()
	end
end

local mdl_decoder = {job = job}

function mdl_decoder.Gather(path, full_path)
	local res = resource.Load(vfs, full_path)
	local ok, data = pcall(resource.ReadKV3, res)
	local external = 0
	local masks = {}

	if ok then
		external = #data.m_refMeshes
		local lods = data.m_refLODGroupMasks or {}
		local groups = data.m_refMeshGroupMasks or {}
		local default = data.m_nDefaultMeshGroupMask or -1
		local count = math.max(#lods, #groups)
		local any = false

		-- a mesh is drawn when it is in the most detailed lod and in a mesh group that is on by default
		for i = 1, count do
			local lod_ok = bit.band(lods[i] or 1, 1) ~= 0
			local group_ok = bit.band(groups[i] or -1, default) ~= 0
			masks[i] = lod_ok and group_ok and 1 or 0
			any = any or masks[i] == 1
		end

		if not any then masks = data.m_refLODGroupMasks or {} end
	else
		data = {m_refMeshes = {}}
	end

	local input = {
		path = path,
		model = res.data,
		masks = masks,
		external = external,
		physics_refs = data.m_refPhysicsData,
		meshes = {},
	}
	local size = #res.data

	for i, mesh in ipairs(data.m_refMeshes) do
		if bit.band(masks[i] or 1, 1) ~= 0 then
			input.meshes[#input.meshes + 1] = assert(vfs.Read(mesh .. "_c"))
			size = size + #input.meshes[#input.meshes]
		end
	end

	return input, size
end

function mdl_decoder.Finish(path, full_path, input, meta, blob_table, mesh_callback, physics_callback)
	finish(path, input, meta, blob_table, mesh_callback, physics_callback)
end

local mesh_decoder = {job = job}

function mesh_decoder.Gather(path, full_path)
	local data = assert(vfs.Read(full_path))
	return {path = path, meshes = {data}}, #data
end

mesh_decoder.Finish = mdl_decoder.Finish
model_loader.AddThreadedDecoder("vmdl_c", mdl_decoder)
model_loader.AddThreadedDecoder("vmesh_c", mesh_decoder)
