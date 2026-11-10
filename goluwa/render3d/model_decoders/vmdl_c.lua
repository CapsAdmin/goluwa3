local ffi = require("ffi")
local bit = require("bit")
local vfs = import("goluwa/vfs.lua")
local tasks = import("goluwa/tasks.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local packed_mesh = import("goluwa/render3d/packed_mesh.lua")
local Skeleton = import("goluwa/render3d/skeleton.lua")
local AABB = import("goluwa/structs/aabb.lua")
local resource = import("goluwa/source_engine/source2/resource.lua")
local animation = import("goluwa/source_engine/source2/animation.lua")
local vphys = import("goluwa/source_engine/source2/vphys.lua")
local s2_material = import("goluwa/source_engine/source2/material.lua")
local f32_ptr_t = ffi.typeof("const float *")
local DECAL_LIFT = 0.03
local job = [=[
	local input = ...
	return import("goluwa/source_engine/source2/mesh_pack.lua").PackModel(input)
]=]
local MAX_CACHED_FRAMES = 64
local pose_stride = Skeleton.PoseSize

local function read_frame(state, animation_index, frame)
	local key = animation_index * 1000000 + frame
	local pose = state.cache[key]

	if pose then return pose end

	local decoder = state.decoder

	if not decoder then
		local res = resource.Parse(state.model)
		decoder = animation.NewDecoder(res, animation.ReadBones(resource.ReadKV3(res), state.cloth_parents), state.kept)
		state.decoder = decoder
	end

	if state.cached == MAX_CACHED_FRAMES then
		state.cache = {}
		state.cached = 0
	end

	pose = ffi.new("float[?]", #state.kept * pose_stride)
	decoder:ReadFrame(animation_index, frame, pose)
	state.cache[key] = pose
	state.cached = state.cached + 1
	return pose
end

local function sample_clip(clip, cycle, pose_parameters, out)
	local state, source = clip.state, clip.source
	local frames = source.frame_count
	local x = math.clamp(cycle, 0, 1) * (source.loop and frames or frames - 1)
	local frame = math.floor(x)

	if not source.loop and frame >= frames - 1 then
		frame = math.max(frames - 2, 0)
	end

	local a = read_frame(state, source.animation, frame % frames)

	if frames == 1 then
		ffi.copy(out, a, clip.skeleton.BoneCount * pose_stride * 4)
		return
	end

	clip.skeleton:BlendPoses(a, read_frame(state, source.animation, (frame + 1) % frames), x - frame, out)
end

local function copy_array(blob_table, offset, ctype, size)
	local array = ffi.new(ctype .. "[?]", size)
	ffi.copy(array, blob_table.ptr + offset, size * ffi.sizeof(ctype))
	return array
end

local function build_skeleton(input, info, blob_table)
	local count = #info.names
	local bind = ffi.new("float[?]", count * 7)
	local inverse_bind = ffi.new("float[?]", count * 12)
	ffi.copy(bind, blob_table.ptr + info.bind_offset, count * 28)
	ffi.copy(inverse_bind, blob_table.ptr + info.inverse_bind_offset, count * 48)
	local skeleton = Skeleton.New{
		BoneNames = info.names,
		Parents = info.parents,
		BindLocal = bind,
		InverseBind = inverse_bind,
	}
	local state = {
		model = input.model,
		kept = info.kept,
		cloth_parents = info.cloth_parents,
		cache = {},
		cached = 0,
	}

	if info.cloth then
		local cloth = info.cloth
		local offsets = cloth.offsets
		skeleton.Cloth = {
			count = cloth.count,
			rod_count = cloth.rod_count,
			node_bone = copy_array(blob_table, offsets.node_bone, "int32_t", cloth.count),
			inv_mass = copy_array(blob_table, offsets.inv_mass, "float", cloth.count),
			attraction = copy_array(blob_table, offsets.attraction, "float", cloth.count),
			gravity = copy_array(blob_table, offsets.gravity, "float", cloth.count),
			target_start = copy_array(blob_table, offsets.target_start, "int32_t", cloth.count + 1),
			target_bone = copy_array(blob_table, offsets.target_bone, "int32_t", cloth.target_count),
			target_offset = copy_array(blob_table, offsets.target_offset, "float", cloth.target_count * 3),
			target_alpha = copy_array(blob_table, offsets.target_alpha, "float", cloth.target_count),
			rod_nodes = copy_array(blob_table, offsets.rod_nodes, "int32_t", cloth.rod_count * 2),
			rod_limits = copy_array(blob_table, offsets.rod_limits, "float", cloth.rod_count * 2),
			bend_count = cloth.bend_count,
			bend_nodes = copy_array(blob_table, offsets.bend_nodes, "int32_t", math.max(cloth.bend_count * 2, 1)),
			bend_rest = copy_array(blob_table, offsets.bend_rest, "float", math.max(cloth.bend_count, 1)),
			capsule_count = cloth.capsule_count,
			capsule_bone = copy_array(blob_table, offsets.capsule_bone, "int32_t", math.max(cloth.capsule_count, 1)),
			capsule_points = copy_array(blob_table, offsets.capsule_points, "float", math.max(cloth.capsule_count * 6, 1)),
			capsule_radius = copy_array(blob_table, offsets.capsule_radius, "float", math.max(cloth.capsule_count * 2, 1)),
		}
	end

	for _, source in ipairs(info.clips) do
		skeleton:AddClip{
			Name = source.name,
			Duration = (source.loop and source.frame_count or source.frame_count - 1) / source.fps,
			Loop = source.loop,
			Sample = sample_clip,
			skeleton = skeleton,
			source = source,
			state = state,
		}
	end

	return skeleton
end

local function finish(path, input, meta, blob_table, mesh_callback, physics_callback, skeleton_callback)
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

	if meta.skeleton then
		skeleton_callback(build_skeleton(input, meta.skeleton, blob_table))
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

		if entry.bone_ids_offset then
			local bone_ids = ffi.new("uint16_t[?]", entry.vertex_count * 4)
			local bone_weights = ffi.new("float[?]", entry.vertex_count * 4)
			ffi.copy(bone_ids, blob_table.ptr + entry.bone_ids_offset, entry.vertex_count * 8)
			ffi.copy(bone_weights, blob_table.ptr + entry.bone_weights_offset, entry.vertex_count * 16)
			polygon.Skin = {BoneIndices = bone_ids, BoneWeights = bone_weights, Flexes = {}}
		end

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

function mdl_decoder.Finish(
	path,
	full_path,
	input,
	meta,
	blob_table,
	mesh_callback,
	physics_callback,
	skeleton_callback
)
	finish(path, input, meta, blob_table, mesh_callback, physics_callback, skeleton_callback)
end

local mesh_decoder = {job = job}

function mesh_decoder.Gather(path, full_path)
	local data = assert(vfs.Read(full_path))
	return {path = path, meshes = {data}}, #data
end

mesh_decoder.Finish = mdl_decoder.Finish
model_loader.AddThreadedDecoder("vmdl_c", mdl_decoder)
model_loader.AddThreadedDecoder("vmesh_c", mesh_decoder)
