local codec = import("goluwa/codec.lua")
local timer = import("goluwa/timer.lua")
local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local file_path = import("goluwa/filesystem/path.lua")
local tasks = import("goluwa/tasks.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local convex_hull = import("goluwa/physics/convex_hull.lua")
local render = import("goluwa/render/render.lua")
local R = vfs.GetAbsolutePath
local ffi = require("ffi")
local bit = require("bit")
local fs = import("goluwa/filesystem/fs.lua")
local Skeleton = import("goluwa/render3d/skeleton.lua")
local _debug = false
local header = [[
	string id[4]; // Model format ID, such as "IDST" (0x49 0x44 0x53 0x54)
	int version; // Format version number, such as 48 (0x30,0x00,0x00,0x00)
	int checksum;
	char name[64]; 	// The internal name of the model, padding with null bytes.
					// Typically "my_model.mdl" will have an internal name of "my_model"

	int file_size; // Data size of MDL file in bytes.

	// A vector is 12 bytes, three 4-byte float-values in a row.

	vec3 eye_position; // Position of player viewpoint relative to model origin
	vec3 illumination_position;	// ?? Presumably the point used for lighting when per-vertex lighting is not enabled.
	vec3 hull_min; // Corner of model hull box with the least X/Y/Z values
	vec3 hull_max; // Opposite corner of model hull box
	vec3 view_bbmin;
	vec3 view_bbmax;

	int flags; 	// Binary flags in little-endian order.
				// ex (00000001,00000000,00000000,11000000) means flags for position 0, 30, and 31 are set.
				// Set model flags section for more information

	/*
	 * After this point, the header contains many references to offsets
	 * within the MDL file and the number of items at those offsets.
	 *
	 * Offsets are from the very beginning of the file.
	 *
	 * Note that indexes/counts are not always paired and ordered consistently.
	 */

	 // mstudiobone_t
	int bone_count;	// Number of data sections (of type mstudiobone_t)
	int bone_offset; // Offset of first data section

	// mstudiobonecontroller_t
	int bonecontroller_count;
	int bonecontroller_offset;

	// mstudiohitboxset_t
	int hitbox_count;
	int hitbox_offset;

	// mstudioanimdesc_t
	int localanim_count;
	int localanim_offset;

	// mstudioseqdesc_t
	int localseq_count;
	int localseq_offset;

	int activitylistversion; // initialization flag - have the sequences been indexed?
	int eventsindexed;	// ??

	// VMT material filenames
	// mstudiotexture_t
	int material_count;
	int material_offset;

	// This offset points to a series of ints.
	// Each int value, in turn, is an offset relative to the start of this header/the-file,
	// At which there is a null-terminated string.
	int texturedir_count;
	int texturedir_offset;

	// Each skin-family assigns a texture-id to a skin location
	int skinreference_count;
	int skinrfamily_count;
	int skinreference_offset;

	// mstudiobodyparts_t
	int bodypart_count;
	int bodypart_offset;

	// Local attachment points
	// mstudioattachment_t
	int attachment_count;
	int attachment_offset;

	// Node values appear to be single bytes, while their names are null-terminated strings.
	int localnode_count;
	int localnode_offset;
	int localnode_name_offset;

	// mstudioflexdesc_t
	int flexdesc_count;
	int flexdesc_offset;

	// mstudioflexcontroller_t
	int flexcontroller_count;
	int flexcontroller_offset;

	// mstudioflexrule_t
	int flexrules_count;
	int flexrules_offset;

	// IK probably referse to inverse kinematics
	// mstudioikchain_t
	int ikchain_count;
	int ikchain_offset;

	// Information about any "mouth" on the model for speech animation
	// More than one sounds pretty creepy.
	// mstudiomouth_t
	int mouths_count;
	int mouths_offset;

	// mstudioposeparamdesc_t
	int localposeparam_count;
	int localposeparam_offset;

	/*
	 * For anyone trying to follow along, as of this writing,
	 * the next "render2dprop_offset" value is at position 0x0134 (308)
	 * from the start of the file.
	 */

	// Surface property value (single null-terminated string)
	//int render2dprop_count;
	int render2dprop_offset;

	// Unusual: In this one index comes first, then count.
	// Key-value data is a series of strings. If you can't find
	// what you're interested in, check the associated PHY file as well.
	int keyvalue_offset;
	int keyvalue_size;

	// More inverse-kinematics
	// mstudioiklock_t
	int iklock_count;
	int iklock_offset;


	float mass; 		// Mass of object (4-bytes)
	int contents;	// ??

	// Other models can be referenced for re-used sequences and animations
	// (See also: The $includemodel QC option.)

	// mstudiomodelgroup_t
	int includemodel_count;
	int includemodel_offset;

	int virtualModel;	// Placeholder for mutable-void*

	// mstudioanimblock_t
	int animblocks_name_offset;
	int animblocks_count;
	int animblocks_offset;

	int animblockModel; // Placeholder for mutable-void*

	// Points to a series of bytes?
	int bonetablename_offset;

	int vertex_base;	// Placeholder for void*
	int offset_base;	// Placeholder for void*

	// Used with $constantdirectionallight from the QC
	// Model should have flag #13 set if enabled
	byte directionaldotproduct;

	byte rootLod;	// Preferred rather than clamped

	// 0 means any allowed, N means Lod 0 -> (N-1)
	byte numAllowedRootLods;

	byte unused; // ??
	int unused; // ??

	// mstudioflexcontrollerui_t
	int flexcontrollerui_count;
	int flexcontrollerui_offset;

	/**
	 * Offset for additional header information.
	 * May be zero if not present, or also 408 if it immediately
	 * follows this studiohdr_t
	 */
	// studiohdr2_t
	int studiohdr2index;

	int unused; // ??

	int source_bone_transform_count;
	int source_bone_transform_offset;

	int illumination_position_attachment_index;
	int max_eye_deflection;
	int linear_bone_offset;
]]

local function find_file(path, ...)
	local extensions = {...}
	local ok, err
	local attempts = {}

	-- try exact path first
	for _, ext in ipairs(extensions) do
		table.insert(attempts, path .. ext)
		ok, err = vfs.Open(path .. ext)

		if ok then return ok end
	end

	-- try vfs mixed case search
	for _, ext in ipairs(extensions) do
		local found = vfs.FindMixedCasePath(path .. ext)

		if found then
			ok, err = vfs.Open(found)

			if ok then return ok end
		end
	end

	-- fallback: use fs module for case-insensitive directory listing
	local dir = path:match("(.+/)")
	local base_name = path:match(".+/(.+)$")

	if dir and base_name then
		local abs_dir = R(dir)

		if abs_dir then
			local files = fs.get_files(abs_dir)

			if files then
				for _, file_name in ipairs(files) do
					for _, ext in ipairs(extensions) do
						local target = base_name .. ext

						if file_name:lower() == target:lower() then
							local full_path = abs_dir .. "/" .. file_name
							table.insert(attempts, full_path)
							ok, err = vfs.Open("os:" .. full_path)

							if ok then return ok end
						end
					end
				end
			end
		end
	end

	error("cannot find mixed case file, attempted: " .. table.concat(attempts, "\n"))
end

local function load_mdl(path)
	local buffer = find_file(path, ".mdl")
	local header = buffer:ReadStructure(header)
	header.name = "models/" .. header.name:remove_padding():gsub("\\", "/")

	local function parse(name, callback)
		local out = {}
		local count = header[name .. "_count"]
		local offset = header[name .. "_offset"]

		if _debug then llog("reading %i %ss (at %i)", count, name, offset) end

		if _debug then profiler.StartTimer(name) end

		if count > 0 then
			buffer:PushPosition(offset)

			for i = 1, count do
				local data = {}

				if callback(data, i) ~= false then out[i] = data end

				if _debug then tasks.ReportProgress("reading " .. name, count) end

				tasks.Wait()
			end

			buffer:PopPosition()
		end

		--header[name .. "_count"] = nil
		--header[name .. "_offset"] = nil
		header[name] = out
	end

	local function string_from_offset(offset, offset2)
		if offset2 == 0 then return "" end

		buffer:PushPosition(offset + offset2)
		local str = buffer:ReadString()
		buffer:PopPosition()
		return str
	end

	do
		header.materials = {}

		if
			header.material_count > 0 and
			header.material_offset > 0 and
			header.material_offset < buffer:GetSize()
		then
			buffer:PushPosition(header.material_offset)

			for i = 1, header.material_count do
				local material_pos = buffer:GetPosition()
				local offset = buffer:ReadI32()

				if offset > 0 then
					local string_pos = material_pos + offset

					if string_pos < buffer:GetSize() then
						buffer:PushPosition(string_pos)
						local mat = file_path.FixPathSlashes(buffer:ReadString())
						buffer:PopPosition()

						if mat ~= "" and not mat:ends_with("/") then
							header.materials[i] = mat
						end
					end
				end

				buffer:Advance(60)
			end

			buffer:PopPosition()
		end

		parse("texturedir", function(data, i)
			local offset = buffer:ReadI32()
			buffer:PushPosition(offset)
			data.path = "materials/" .. file_path.FixPathSlashes(buffer:ReadString())
			buffer:PopPosition()
		end)
	end

	--[[

	local bone_names
	local render2d_prop_names

	parse("bone", function(data, i)
		do -- bone name
			local offset = buffer:ReadI32()
			if not bone_names then
				bone_names = {}
				buffer:PushPosition(header.bone_offset + offset)
					for i = 1, header.bone_count do
						bone_names[i] = buffer:ReadString()
					end
				buffer:PopPosition()
			end
			data.name = bone_names[i]
		end

		data.parent_bone_index = buffer:ReadI32()

		do
			data.controller_index = {}

			for i = 1, 6 do
				data.controller_index[i] = buffer:ReadI32()
			end
		end

		data.position = buffer:ReadVec3()

		data.quat = buffer:ReadQuat()

		data.rotation = buffer:ReadVec3()
		data.position_scale = buffer:ReadVec3()
		data.rotation_scale = buffer:ReadVec3()

		local matrix = Matrix44()
		for i = 1, 12 do
			local val = buffer:ReadFloat()
			--matrix[-i-12] = val
		end

		data.pose_to_bone = matrix

		data.quat_alignment = buffer:ReadQuat()

		data.flags = buffer:ReadI32()
		data.procedural_rule_type = buffer:ReadI32()
		data.procedural_rule_offset = buffer:ReadI32()
		data.physics_bone_index = buffer:ReadI32()

		do -- bone name
			local offset = buffer:ReadI32()
			if not render2d_prop_names then
				render2d_prop_names = {}
				buffer:PushPosition(header.bone_offset + offset)
					for i = 1, header.bone_count do
						render2d_prop_names[i] = buffer:ReadString()
					end
				buffer:PopPosition()
			end
			data.render2d_prop_name = render2d_prop_names[i]
		end

		data.contents = buffer:ReadI32()

		buffer:Advance(32)
	end)

	parse("mouths", function(data, i)
		data.bone_index = buffer:ReadI32()
		data.forward = buffer:ReadVec3()
		data.flex_desc_index = buffer:ReadI32()
	end)

	parse("localseq", function(data, i)
		do return end
		data.base_header_offset = buffer:ReadI32()
		data.name = string_from_offset(header.localanim_offset, buffer:ReadI32())
		data.activity_name = string_from_offset(header.localanim_offset, buffer:ReadI32())
		data.flags = buffer:ReadI32()
		data.activity = buffer:ReadI32()
		data.activity_weight = buffer:ReadI32()
		data.event_count = buffer:ReadI32()
		data.event_offset = buffer:ReadI32()

		data.bb_min = buffer:ReadVec3()
		data.bb_max = buffer:ReadVec3()

		data.blend_count = buffer:ReadI32()
		data.anim_index_offset = buffer:ReadI32()

		data.group_size = {buffer:ReadI32(), buffer:ReadI32()}

		data.param_index = {buffer:ReadI32(), buffer:ReadI32()}
		data.param_start = {buffer:ReadFloat(), buffer:ReadFloat()}
		data.param_end = {buffer:ReadFloat(), buffer:ReadFloat()}
		data.param_parent = buffer:ReadI32()

		data.fade_in_time = buffer:ReadFloat()
		data.fade_out_time = buffer:ReadFloat()

		data.localEntryNodeIndex = buffer:ReadI32()
		data.localExitNodeIndex = buffer:ReadI32()
		data.nodeFlags = buffer:ReadI32()

		data.entryPhase = buffer:ReadFloat()
		data.exitPhase = buffer:ReadFloat()
		data.lastFrame = buffer:ReadFloat()

		data.nextSeq = buffer:ReadI32()
		data.pose = buffer:ReadI32()

		data.ikRuleCount = buffer:ReadI32()
		data.autoLayerCount = buffer:ReadI32()
		data.autoLayerOffset = buffer:ReadI32()
		data.weightOffset = buffer:ReadI32()
		data.poseKeyOffset = buffer:ReadI32()

		data.ikLockCount = buffer:ReadI32()
		data.ikLockOffset = buffer:ReadI32()
		data.keyValueOffset = buffer:ReadI32()
		data.keyValueSize = buffer:ReadI32()
		data.cyclePoseIndex = buffer:ReadI32()
	end)

	buffer:PushPosition(header.keyvalue_offset)
		local str = buffer:ReadString(header.keyvalue_size)
		if str then
			header.keyvalues = utility.VDFToTable(str)
		end
		header.keyvalue_offset = nil
		header.keyvalue_count = nil
	buffer:PopPosition()

	logn("these remain to be parsed:")

	for k,v in pairs(header) do
		if k:find("_count") then
			if header[k:gsub("_count", "_offset")] then
				local name = k:gsub("_count", "")
				logf("\t%s (count: %s|offset: %s)\n", name, header[name.."_count"], header[name.."_offset"])
			end
		end
	end]]
	-- where the vertices of each model and mesh start in the vvd, and which material a mesh uses. the vtx lists
	-- bodyparts, models and meshes in this same order. sizes are mstudiobodyparts_t 16, mstudiomodel_t 148, mstudiomesh_t 116
	header.bodypart_models = {}

	for bodypart_i = 1, header.bodypart_count do
		local bodypart_pos = header.bodypart_offset + (bodypart_i - 1) * 16
		buffer:SetPosition(bodypart_pos + 4)
		local model_count = buffer:ReadI32()
		buffer:Advance(4)
		local models_pos = bodypart_pos + buffer:ReadI32()
		local models = {}

		for model_i = 1, model_count do
			local model_pos = models_pos + (model_i - 1) * 148
			buffer:SetPosition(model_pos + 72)
			local mesh_count = buffer:ReadI32()
			local meshes_pos = model_pos + buffer:ReadI32()
			buffer:Advance(4)
			local model = {vertex_start = buffer:ReadI32() / 48, meshes = {}}

			for mesh_i = 1, mesh_count do
				buffer:SetPosition(meshes_pos + (mesh_i - 1) * 116)
				local material = buffer:ReadI32()
				buffer:Advance(8)
				model.meshes[mesh_i] = {material = material, vertex_offset = buffer:ReadI32()}
			end

			models[model_i] = model
		end

		header.bodypart_models[bodypart_i] = models
	end

	return header
end

-- version 49 models append numTopologyIndices and topologyOffset to the strip group header
local function load_vtx(path, strip_group_size)
	local MAX_NUM_BONES_PER_VERT = 3
	local buffer = find_file(path, ".dx90.vtx", ".dx80.vtx", ".sw.vtx")
	local vtx = buffer:ReadStructure([[
		long version;
		long vertex_cache_size;
		short max_bones_per_strip;
		short max_bones_per_tri;
		long max_bones_per_vertex;
		long checksum;
		long lod_count;
		long material_replacement_list_offset;
	]])
	vtx.body_part_count = buffer:ReadI32()
	vtx.body_part_offset = buffer:ReadI32()
	buffer:PushPosition(vtx.body_part_offset)
	vtx.body_parts = {}

	for i = 1, vtx.body_part_count do
		local stream_pos = buffer:GetPosition()
		local body_part = {}
		body_part.model_count = buffer:ReadI32()
		body_part.model_offset = buffer:ReadI32()
		vtx.body_parts[i] = body_part
		buffer:PushPosition(stream_pos + body_part.model_offset)
		body_part.models = {}

		for i = 1, body_part.model_count do
			local stream_pos = buffer:GetPosition()
			local model = {}
			model.lod_count = buffer:ReadI32()
			model.lod_offset = buffer:ReadI32()
			body_part.models[i] = model
			buffer:PushPosition(stream_pos + model.lod_offset)
			model.model_lods = {}

			for i = 1, model.lod_count do
				local stream_pos = buffer:GetPosition()
				local lod_model = {}
				lod_model.mesh_count = buffer:ReadI32()
				lod_model.mesh_offset = buffer:ReadI32()
				lod_model.switchPoint = buffer:Advance(4) --buffer:ReadFloat()
				model.model_lods[i] = lod_model
				buffer:PushPosition(stream_pos + lod_model.mesh_offset)
				lod_model.meshes = {}

				for i = 1, lod_model.mesh_count do
					local stream_pos = buffer:GetPosition()
					local mesh = {}
					mesh.strip_group_count = buffer:ReadI32()
					mesh.strip_group_offset = buffer:ReadI32()
					mesh.flags = buffer:ReadByte()
					lod_model.meshes[i] = mesh
					buffer:PushPosition(stream_pos + mesh.strip_group_offset)
					mesh.strip_groups = {}

					for i = 1, mesh.strip_group_count do
						local stream_pos = buffer:GetPosition()
						local strip_group = {}
						strip_group.vertices_count = buffer:ReadI32()
						strip_group.vertices_offset = buffer:ReadI32()
						strip_group.indices_count = buffer:ReadI32()
						strip_group.indices_offset = buffer:ReadI32()
						strip_group.strip_count = buffer:ReadI32()
						strip_group.strip_offset = buffer:ReadI32()
						strip_group.flags = buffer:ReadByte()
						buffer:Advance(strip_group_size - 25)
						mesh.strip_groups[i] = strip_group
						local vertices = {}
						buffer:PushPosition(stream_pos + strip_group.vertices_offset)

						for i = 1, strip_group.vertices_count do
							local vertex = {} --{bone_weight_indices = {}, boneId = {}}
							buffer:Advance(MAX_NUM_BONES_PER_VERT + 1)
							--[[
							for i = 1, MAX_NUM_BONES_PER_VERT do
								vertex.bone_weight_indices[i] = buffer:ReadByte()
							end
							vertex.bone_count = buffer:ReadByte()
							]]
							vertex.mesh_vertex_index = buffer:ReadI16()
							buffer:Advance(MAX_NUM_BONES_PER_VERT)
							--[[
							for i = 1, MAX_NUM_BONES_PER_VERT do
								vertex.boneId[i] = buffer:ReadByte()
							end]]
							vertices[i] = vertex
						end

						buffer:PopPosition()
						local indices = {}
						buffer:PushPosition(stream_pos + strip_group.indices_offset)

						for i = 1, strip_group.indices_count do
							indices[i] = buffer:ReadI16() + 1
						end

						buffer:PopPosition()
						local strips = {}
						buffer:PushPosition(stream_pos + strip_group.strip_offset)

						for i = 1, strip_group.strip_count do
							local stream_pos = buffer:GetPosition()
							local strip = {}
							strip.indices_count = buffer:ReadI32()
							strip.indices_offset = buffer:ReadI32()
							strip.vertices_count = buffer:ReadI32()
							strip.vertices_offset = buffer:ReadI32()
							buffer:Advance(2 + 1 + 8)
							--strip.bone_count = buffer:ReadI16()
							--strip.flags = buffer:ReadByte()
							--[[
							strip.bone_state_change_count = buffer:ReadI32()
							strip.bone_state_change_offset = buffer:ReadI32()

							local bone_state_changes = {}
							buffer:PushPosition(stream_pos + strip.bone_state_change_offset)
							for i = 1, strip.bone_state_change_count do
								bone_state_changes[i] = {}
								bone_state_changes[i].hardware_id = buffer:ReadI32()
								bone_state_changes[i].new_bone_id = buffer:ReadI32()
							end
							buffer:PopPosition()
							strip.bone_state_changes = bone_state_changes
]]
							strip.indices = indices
							strip.vertices = vertices
							strips[i] = strip
						end

						buffer:PopPosition()
						strip_group.strips = strips

						if _debug then
							tasks.ReportProgress(
								"reading body parts",
								vtx.body_part_count * body_part.model_count * model.lod_count * lod_model.mesh_count * mesh.strip_group_count
							)
						end

						tasks.Wait()
					end

					buffer:PopPosition()
				end

				buffer:PopPosition()
			end

			buffer:PopPosition()
		end

		buffer:PopPosition()
	end

	buffer:PopPosition()
	return vtx
end

local function load_vvd(path)
	local MAX_NUM_LODS = 8
	local MAX_NUM_BONES_PER_VERT = 3
	local buffer = find_file(path, ".vvd")
	local vvd = {lod_vertices_count = {}}
	vvd.id = buffer:ReadBytes(4)
	vvd.version = buffer:ReadI32()
	vvd.checksum = buffer:ReadI32()
	vvd.lod_count = buffer:ReadI32()

	for i = 1, MAX_NUM_LODS do
		vvd.lod_vertices_count[i] = buffer:ReadI32()
	end

	vvd.fixup_count = buffer:ReadI32()
	vvd.fixup_offset = buffer:ReadI32()
	vvd.vertices_offset = buffer:ReadI32()
	vvd.tangentDataOffset = buffer:ReadI32()
	vvd.vertices = {}

	local function read_vertex(i)
		--[[
		local boneWeight = {weight = {}, bone = {}}

		for x = 1, MAX_NUM_BONES_PER_VERT do
			boneWeight.weight[x] = buffer:ReadFloat()
		end
		for x = 1, MAX_NUM_BONES_PER_VERT do
			boneWeight.bone[x] = buffer:ReadByte()
		end
		boneWeight.bone_count = buffer:ReadByte()
		]]
		local vertex = {}
		local weights = {}
		local bones = {}

		for x = 1, MAX_NUM_BONES_PER_VERT do
			weights[x] = buffer:ReadFloat()
		end

		for x = 1, MAX_NUM_BONES_PER_VERT do
			bones[x] = buffer:ReadByte()
		end

		vertex.bone_weights = weights
		vertex.bone_ids = bones
		vertex.bone_count = buffer:ReadByte()
		local x, y, z = buffer:ReadFloat(), buffer:ReadFloat(), buffer:ReadFloat()
		-- Source: X=forward, Y=left, Z=up
		-- Engine: X=right, Y=up, Z=forward  
		-- Transform: our_x = -source_y, our_y = source_z, our_z = -source_x
		vertex.pos = Vec3(-y, z, -x) * steam.source2meters
		local nx, ny, nz = buffer:ReadFloat(), buffer:ReadFloat(), buffer:ReadFloat()
		vertex.normal = Vec3(-ny, nz, -nx)
		vertex.uv = buffer:ReadVec2()
		vvd.vertices[i] = vertex

		if _debug then tasks.ReportProgress("reading vertices", vertices_count) end

		tasks.Wait()
	end

	if vvd.lod_count > 0 and vvd.fixup_count == 0 then
		local vertices_count = vvd.lod_vertices_count[1]
		buffer:SetPosition(vvd.vertices_offset)

		for i = 1, vertices_count do
			read_vertex(i)
		end
	end

	vvd.fixed_vertices_by_lod = {}

	if vvd.fixup_count > 0 and vvd.fixup_offset ~= 0 then
		buffer:SetPosition(vvd.fixup_offset)
		vvd.theFixups = {}

		for i = 1, vvd.fixup_count do
			local fixup = {}
			fixup.lod_index = buffer:ReadI32() + 1
			fixup.vertex_index = buffer:ReadI32() + 1
			fixup.vertices_count = buffer:ReadI32()
			vvd.theFixups[i] = fixup
		end

		if vvd.lod_count > 0 then
			buffer:SetPosition(vvd.vertices_offset)

			for lod_index = 1, vvd.lod_count do
				vvd.fixed_vertices_by_lod[lod_index] = {}
				local i2 = 1

				for _, fixup in ipairs(vvd.theFixups) do
					if fixup.lod_index >= lod_index then
						for i = 1, fixup.vertices_count do
							local vertex_i = fixup.vertex_index + (i - 1)
							buffer:SetPosition(
								vvd.vertices_offset + (
										(
											(
												4 * MAX_NUM_BONES_PER_VERT
											) + MAX_NUM_BONES_PER_VERT + 1
										) + 12 + 12 + 8
									) * (
										vertex_i - 1
									)
							)
							read_vertex(vertex_i)
							vvd.fixed_vertices_by_lod[lod_index][i2] = vvd.vertices[fixup.vertex_index + (i - 1)]
							i2 = i2 + 1
						end
					end
				end

				-- only first lod needed
				break
			end
		end
	end

	return vvd
end

-- phy points are ivp meters, 1 ivp meter = 39.37 source units, and ivp y/z are swapped relative to source
local PHY_TO_METERS = steam.source2meters / 0.0254

local function load_phy(path)
	local buffer = find_file(path, ".phy")
	local header_size = buffer:ReadI32()
	buffer:Advance(4)
	local solid_count = buffer:ReadI32()
	buffer:SetPosition(header_size)
	local solids = {}

	for solid_i = 1, solid_count do
		local surface_size = buffer:ReadI32()
		local solid_start = buffer:GetPosition()
		-- compactsurfaceheader_t is 28 bytes after the size, then the ivp compact surface
		local surface_start = solid_start + 28
		buffer:SetPosition(surface_start)
		local cx, cy, cz = buffer:ReadFloat(), buffer:ReadFloat(), buffer:ReadFloat()
		local ix, iy, iz = buffer:ReadFloat(), buffer:ReadFloat(), buffer:ReadFloat()
		buffer:SetPosition(surface_start + 32)
		local ledgetree_root = surface_start + buffer:ReadI32()
		local ledges = {}
		local stack = {ledgetree_root}

		while stack[1] do
			local node_pos = table.remove(stack)
			assert(
				node_pos >= solid_start and node_pos < solid_start + surface_size,
				"phy ledge tree node out of range"
			)
			buffer:SetPosition(node_pos)
			local right_offset = buffer:ReadI32()
			local convex_offset = buffer:ReadI32()

			if right_offset == 0 then
				local ledge_pos = node_pos + convex_offset
				buffer:SetPosition(ledge_pos)
				local point_offset = buffer:ReadI32()
				buffer:Advance(8)
				local triangle_count = buffer:ReadI16()
				buffer:Advance(2)
				assert(
					triangle_count > 0 and triangle_count < 4096,
					"phy ledge triangle count out of range"
				)
				local used = {}
				local indices = {}

				for i = 1, triangle_count do
					buffer:Advance(4)

					for edge = 1, 3 do
						local index = bit.band(buffer:ReadI32(), 0xffff)

						if not used[index] then
							used[index] = true
							indices[#indices + 1] = index
						end
					end
				end

				local points = {}

				for i, index in ipairs(indices) do
					buffer:SetPosition(ledge_pos + point_offset + index * 16)
					local x, y, z = buffer:ReadFloat(), buffer:ReadFloat(), buffer:ReadFloat()
					points[i] = Vec3(-z, -y, -x) * PHY_TO_METERS
				end

				ledges[#ledges + 1] = points
			else
				stack[#stack + 1] = node_pos + right_offset
				stack[#stack + 1] = node_pos + 28
			end
		end

		solids[solid_i] = {
			ledges = ledges,
			mass_center = Vec3(-cz, -cy, -cx) * PHY_TO_METERS,
			rotation_inertia = Vec3(ix, iy, iz),
		}
		buffer:SetPosition(solid_start + surface_size)
	end

	local text = buffer:ReadString(tonumber(buffer:GetSize() - buffer:GetPosition()))
	local index = 0

	for block in text:gmatch("solid%s*(%b{})") do
		local solid = solids[tonumber(block:match("\"index\"%s*\"([^\"]*)\"")) + 1]

		if solid then
			solid.mass = tonumber(block:match("\"mass\"%s*\"([^\"]*)\""))
			solid.surface_property = block:match("\"surfaceprop\"%s*\"([^\"]*)\"")
		end
	end

	return solids
end

local load_skeleton

do -- animation
	local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
	local U8 = ffi.typeof("const uint8_t*")
	local I16 = ffi.typeof("const int16_t*")
	local U16 = ffi.typeof("const uint16_t*")
	local I32 = ffi.typeof("const int32_t*")
	local U32 = ffi.typeof("const uint32_t*")
	local F32 = ffi.typeof("const float*")
	local SCALE = steam.source2meters
	local BONE_SIZE = 216
	local ANIMDESC_SIZE = 100
	local SEQDESC_SIZE = 212
	local POSEPARAM_SIZE = 20
	local ANIM_RAWPOS = 0x01
	local ANIM_RAWROT = 0x02
	local ANIM_ANIMPOS = 0x04
	local ANIM_ANIMROT = 0x08
	local ANIM_DELTA = 0x10
	local ANIM_RAWROT2 = 0x20
	local SEQ_LOOPING = 0x0001
	local SEQ_DELTA = 0x0004
	local ANIMDESC_DELTA = 0x0004
	local ANIMDESC_ALLZEROS = 0x0020
	local ANIMDESC_FRAMEANIM = 0x0040
	-- source (x forward, y left, z up) to engine (x right, y up, z forward): p_e = SCALE * (-y, z, -x), a rotation times a scale
	local R = {{0, -1, 0}, {0, 0, 1}, {-1, 0, 0}}

	local function half_to_float(h)
		local sign = h >= 0x8000 and -1 or 1
		local exponent = band(rshift(h, 10), 0x1f)
		local mantissa = band(h, 0x3ff)

		if exponent == 0 then return sign * mantissa * 2 ^ -24 end

		if exponent == 31 then return sign * math.huge end

		return sign * (1 + mantissa / 1024) * 2 ^ (exponent - 15)
	end

	local function euler_to_quat(x, y, z)
		local sr, cr = math.sin(x * 0.5), math.cos(x * 0.5)
		local sp, cp = math.sin(y * 0.5), math.cos(y * 0.5)
		local sy, cy = math.sin(z * 0.5), math.cos(z * 0.5)
		return sr * cp * cy - cr * sp * sy,
		cr * sp * cy + sr * cp * sy,
		cr * cp * sy - sr * sp * cy,
		cr * cp * cy + sr * sp * sy
	end

	local function quat_to_matrix(x, y, z, w)
		return {
			{
				1 - 2 * (
					y * y + z * z
				),
				2 * (
					x * y - w * z
				),
				2 * (
					x * z + w * y
				),
			},
			{
				2 * (
					x * y + w * z
				),
				1 - 2 * (
					x * x + z * z
				),
				2 * (
					y * z - w * x
				),
			},
			{
				2 * (
					x * z - w * y
				),
				2 * (
					y * z + w * x
				),
				1 - 2 * (
					x * x + y * y
				),
			},
		}
	end

	-- R * m * R^t
	local function conjugate(m)
		local out = {{}, {}, {}}

		for i = 1, 3 do
			for j = 1, 3 do
				local sum = 0

				for k = 1, 3 do
					for l = 1, 3 do
						sum = sum + R[i][k] * m[k][l] * R[j][l]
					end
				end

				out[i][j] = sum
			end
		end

		return out
	end

	local sources = {}

	-- a mdl file kept in memory for sampling its animations later. shared between every model that includes it
	local function open_source(path)
		local key = path:lower()

		if sources[key] then return sources[key] end

		local buffer = find_file(path, ".mdl")
		local hdr = buffer:ReadStructure(header)
		buffer:SetPosition(0)
		local bytes = buffer:ReadBytes(buffer:GetSize())
		local data = ffi.new("uint8_t[?]", #bytes)
		ffi.copy(data, bytes, #bytes)
		local source = {path = path, header = hdr, data = data, blocks = {}}
		local bone_count = hdr.bone_count
		source.bone_names = {}
		source.bone_parents = {}
		-- per bone: position 0, euler rotation 3, position scale 6, rotation scale 9, quaternion 12
		source.bones = ffi.new("float[?]", math.max(bone_count, 1) * 16)

		for i = 0, bone_count - 1 do
			local bone = data + hdr.bone_offset + i * BONE_SIZE
			source.bone_names[i + 1] = ffi.string(bone + ffi.cast(I32, bone)[0])
			source.bone_parents[i + 1] = ffi.cast(I32, bone + 4)[0]
			local f = ffi.cast(F32, bone)
			local o = i * 16

			for k = 0, 2 do
				source.bones[o + k] = f[8 + k]
				source.bones[o + 3 + k] = f[15 + k]
				source.bones[o + 6 + k] = f[18 + k]
				source.bones[o + 9 + k] = f[21 + k]
			end

			for k = 0, 3 do
				source.bones[o + 12 + k] = f[11 + k]
			end
		end

		source.pose_parameter_names = {}

		for i = 0, hdr.localposeparam_count - 1 do
			local desc = data + hdr.localposeparam_offset + i * POSEPARAM_SIZE
			source.pose_parameter_names[i] = ffi.string(desc + ffi.cast(I32, desc)[0])
		end

		source.includes = {}

		for i = 0, hdr.includemodel_count - 1 do
			local group = data + hdr.includemodel_offset + i * 8
			local name = ffi.string(group + ffi.cast(I32, group + 4)[0])
			source.includes[#source.includes + 1] = (name:gsub("\\", "/"):gsub("%.mdl$", ""))
		end

		sources[key] = source
		return source
	end

	-- the data of an animation block, which lives in the model's .ani file
	local function get_block_data(source, block)
		local cached = source.blocks[block]

		if cached then return cached end

		if not source.ani then
			local name = ffi.string(source.data + source.header.animblocks_name_offset):gsub("\\", "/"):gsub("%.ani$", "")
			local buffer = find_file(name, ".ani")
			buffer:SetPosition(0)
			local bytes = buffer:ReadBytes(buffer:GetSize())
			source.ani = ffi.new("uint8_t[?]", #bytes)
			ffi.copy(source.ani, bytes, #bytes)
		end

		local datastart = ffi.cast(I32, source.data + source.header.animblocks_offset + block * 8)[0]
		cached = source.ani + datastart
		source.blocks[block] = cached
		return cached
	end

	-- first value of an animated channel at a frame, a run length encoded list of shorts
	local function extract_value(v, frame)
		local k = frame
		local valid, total = v[0], v[1]

		while total <= k do
			k = k - total
			v = v + (valid + 1) * 2
			valid, total = v[0], v[1]

			if total == 0 then return 0 end
		end

		if valid > k then return ffi.cast(I16, v + (k + 1) * 2)[0] end

		return ffi.cast(I16, v + valid * 2)[0]
	end

	local function get_anim_chain(source, desc, frame)
		local numframes = ffi.cast(I32, desc + 16)[0]
		local block = ffi.cast(I32, desc + 52)[0]
		local index = ffi.cast(I32, desc + 56)[0]
		local section_frames = ffi.cast(I32, desc + 84)[0]

		if section_frames ~= 0 then
			local section

			if numframes > section_frames and frame == numframes - 1 then
				frame = 0
				section = math.floor(numframes / section_frames) + 1
			else
				section = math.floor(frame / section_frames)
				frame = frame - section * section_frames
			end

			local record = desc + ffi.cast(I32, desc + 80)[0] + section * 8
			block = ffi.cast(I32, record)[0]
			index = ffi.cast(I32, record + 4)[0]
		end

		if block == 0 then return desc + index, frame end

		return get_block_data(source, block) + index, frame
	end

	-- writes the local pose of every bone the animation touches at an integer frame, in engine space, into out
	local function decode_frame(source, desc, frame, bone_map, out)
		local chain
		chain, frame = get_anim_chain(source, desc, frame)
		local bones = source.bones
		local p = chain

		while true do
			local bone = p[0]
			local flags = p[1]
			local target = bone_map[bone]

			if target >= 0 then
				local b = bone * 16
				local qx, qy, qz, qw

				if band(flags, ANIM_RAWROT) ~= 0 then
					local q = ffi.cast(U16, p + 4)
					qx = (q[0] - 32768) / 32768
					qy = (q[1] - 32768) / 32768
					qz = (band(q[2], 0x7fff) - 16384) / 16384
					qw = math.sqrt(math.max(0, 1 - qx * qx - qy * qy - qz * qz))

					if q[2] >= 0x8000 then qw = -qw end
				elseif band(flags, ANIM_RAWROT2) ~= 0 then
					local q = ffi.cast(U32, p + 4)
					local lo, hi = q[0], q[1]
					qx = (band(lo, 0x1fffff) - 1048576) / 1048576.5
					qy = (
							band(bor(rshift(lo, 21), lshift(band(hi, 0x3ff), 11)), 0x1fffff) - 1048576
						) / 1048576.5
					qz = (band(rshift(hi, 10), 0x1fffff) - 1048576) / 1048576.5
					qw = math.sqrt(math.max(0, 1 - qx * qx - qy * qy - qz * qz))

					if rshift(hi, 31) ~= 0 then qw = -qw end
				elseif band(flags, ANIM_ANIMROT) ~= 0 then
					local offsets = ffi.cast(I16, p + 4)
					local o0, o1, o2 = offsets[0], offsets[1], offsets[2]
					local a0, a1, a2 = bones[b + 3], bones[b + 4], bones[b + 5]

					if o0 ~= 0 then
						a0 = a0 + extract_value(p + 4 + o0, frame) * bones[b + 9]
					end

					if o1 ~= 0 then
						a1 = a1 + extract_value(p + 4 + o1, frame) * bones[b + 10]
					end

					if o2 ~= 0 then
						a2 = a2 + extract_value(p + 4 + o2, frame) * bones[b + 11]
					end

					qx, qy, qz, qw = euler_to_quat(a0, a1, a2)
				else
					qx, qy, qz, qw = bones[b + 12], bones[b + 13], bones[b + 14], bones[b + 15]
				end

				local px, py, pz

				if band(flags, ANIM_RAWPOS) ~= 0 then
					local offset = 4

					if band(flags, ANIM_RAWROT) ~= 0 then
						offset = offset + 6
					elseif band(flags, ANIM_RAWROT2) ~= 0 then
						offset = offset + 8
					end

					local v = ffi.cast(U16, p + offset)
					px, py, pz = half_to_float(v[0]), half_to_float(v[1]), half_to_float(v[2])
				elseif band(flags, ANIM_ANIMPOS) ~= 0 then
					local offset = 4

					if band(flags, ANIM_ANIMROT) ~= 0 then offset = offset + 6 end

					local offsets = ffi.cast(I16, p + offset)
					local o0, o1, o2 = offsets[0], offsets[1], offsets[2]
					px, py, pz = bones[b], bones[b + 1], bones[b + 2]

					if o0 ~= 0 then
						px = px + extract_value(p + offset + o0, frame) * bones[b + 6]
					end

					if o1 ~= 0 then
						py = py + extract_value(p + offset + o1, frame) * bones[b + 7]
					end

					if o2 ~= 0 then
						pz = pz + extract_value(p + offset + o2, frame) * bones[b + 8]
					end
				else
					px, py, pz = bones[b], bones[b + 1], bones[b + 2]
				end

				local o = target * 7
				out[o] = -py * SCALE
				out[o + 1] = pz * SCALE
				out[o + 2] = -px * SCALE
				out[o + 3] = -qy
				out[o + 4] = qz
				out[o + 5] = -qx
				out[o + 6] = qw
			end

			local next_offset = ffi.cast(I16, p + 2)[0]

			if next_offset == 0 then break end

			p = p + next_offset
		end
	end

	local scratch_cache = setmetatable({}, {__mode = "k"})

	-- animation desc sampled at a cycle 0..1 (interpolating between frames) over the poses already in out
	local function sample_anim(clip, source, desc, bone_map, cycle, out)
		local skeleton = clip.skeleton
		local numframes = ffi.cast(I32, desc + 16)[0]
		local flags = ffi.cast(I32, desc + 12)[0]

		if band(flags, ANIMDESC_ALLZEROS) ~= 0 then return end

		local frame = numframes > 1 and cycle * (numframes - 1) or 0
		local f0 = math.floor(frame)
		local t = frame - f0
		decode_frame(source, desc, f0, bone_map, out)

		if t > 0.001 and f0 + 1 < numframes then
			local scratch = scratch_cache[skeleton]

			if not scratch then
				scratch = skeleton:CreatePose()
				scratch_cache[skeleton] = scratch
			end

			ffi.copy(scratch, out, skeleton.BoneCount * 28)
			decode_frame(source, desc, f0 + 1, bone_map, scratch)
			skeleton:BlendPoses(out, scratch, t, out)
		end
	end

	local blend_scratch = setmetatable({}, {__mode = "k"})

	-- where a pose parameter puts a sequence along one blend axis: the lower blend and how far to the next one
	local function axis_position(clip, axis, params)
		local size = clip.group_size[axis]
		local name = clip.param_names[axis]

		if size < 2 or not name then return 0, 0 end

		local first, last = clip.param_start[axis], clip.param_end[axis]
		local s = last ~= first and ((params[name] or 0) - first) / (last - first) or 0
		local x = math.clamp(s, 0, 1) * (size - 1)
		local i = math.min(math.floor(x), size - 2)
		return i, x - i
	end

	local function sample_sequence(clip, cycle, params, out)
		local skeleton = clip.skeleton
		local bind = skeleton.BindLocal
		ffi.copy(out, bind, skeleton.BoneCount * 28)
		local source = clip.source
		local ix, fx = axis_position(clip, 1, params)
		local iy, fy = axis_position(clip, 2, params)
		local gx = clip.group_size[1]
		local accumulated = 0
		local scratch = blend_scratch[skeleton]

		if not scratch then
			scratch = skeleton:CreatePose()
			blend_scratch[skeleton] = scratch
		end

		for dy = 0, fy > 0 and 1 or 0 do
			for dx = 0, fx > 0 and 1 or 0 do
				local weight = (dx == 1 and fx or 1 - fx) * (dy == 1 and fy or 1 - fy)

				if weight > 0 then
					local desc = clip.anims[(ix + dx) + (iy + dy) * gx + 1]

					if accumulated == 0 then
						sample_anim(clip, source, desc, clip.bone_map, cycle, out)
					else
						ffi.copy(scratch, bind, skeleton.BoneCount * 28)
						sample_anim(clip, source, desc, clip.bone_map, cycle, scratch)
						skeleton:BlendPoses(out, scratch, weight / (accumulated + weight), out)
					end

					accumulated = accumulated + weight
				end
			end
		end
	end

	-- skeleton and clips of a model, nil when it has nothing to animate
	load_skeleton = function(path)
		local main = open_source(path)
		local hdr = main.header

		if hdr.bone_count < 2 then return end

		local count = hdr.bone_count
		local bind_local = ffi.new("float[?]", count * 7)
		local inverse_bind = ffi.new("float[?]", count * 12)
		local parents = {}

		for i = 0, count - 1 do
			local o = i * 16
			bind_local[i * 7] = -main.bones[o + 1] * SCALE
			bind_local[i * 7 + 1] = main.bones[o + 2] * SCALE
			bind_local[i * 7 + 2] = -main.bones[o] * SCALE
			bind_local[i * 7 + 3] = -main.bones[o + 13]
			bind_local[i * 7 + 4] = main.bones[o + 14]
			bind_local[i * 7 + 5] = -main.bones[o + 12]
			bind_local[i * 7 + 6] = main.bones[o + 15]
			parents[i + 1] = main.bone_parents[i + 1]
			-- matrix3x4 the bone's bind pose inverse, rows of [rotation | translation]
			local m = ffi.cast(F32, main.data + hdr.bone_offset + i * BONE_SIZE + 96)
			local rotation = conjugate{{m[0], m[1], m[2]}, {m[4], m[5], m[6]}, {m[8], m[9], m[10]}}
			local t = {m[3], m[7], m[11]}

			for row = 1, 3 do
				for column = 1, 3 do
					inverse_bind[i * 12 + (row - 1) * 4 + column - 1] = rotation[row][column]
				end

				inverse_bind[i * 12 + (row - 1) * 4 + 3] = SCALE * (R[row][1] * t[1] + R[row][2] * t[2] + R[row][3] * t[3])
			end
		end

		local skeleton = Skeleton.New{
			BoneNames = main.bone_names,
			Parents = parents,
			BindLocal = bind_local,
			InverseBind = inverse_bind,
		}
		local bone_index_by_name = {}

		for i, name in ipairs(main.bone_names) do
			bone_index_by_name[name:lower()] = i - 1
		end

		local visited = {}

		local function add_clips(source)
			if visited[source] then return end

			visited[source] = true
			local shdr = source.header
			local bone_map = ffi.new("int32_t[?]", math.max(shdr.bone_count, 1))

			for i = 0, shdr.bone_count - 1 do
				bone_map[i] = bone_index_by_name[source.bone_names[i + 1]:lower()] or -1
			end

			for i = 0, shdr.localseq_count - 1 do
				local seq = source.data + shdr.localseq_offset + i * SEQDESC_SIZE
				local seq_i32 = ffi.cast(I32, seq)
				local name = ffi.string(seq + seq_i32[1])
				local flags = seq_i32[3]
				local blend_count = seq_i32[14]

				if
					band(flags, SEQ_DELTA) == 0 and
					blend_count > 0 and
					not skeleton.ClipsByName[name]
				then
					local anims = {}
					local usable = true
					local indices = ffi.cast(I16, seq + seq_i32[15])

					for b = 0, blend_count - 1 do
						local index = indices[b]
						local desc = source.data + shdr.localanim_offset + index * ANIMDESC_SIZE
						local desc_flags = ffi.cast(I32, desc + 12)[0]

						if
							band(desc_flags, ANIMDESC_DELTA) ~= 0 or
							band(desc_flags, ANIMDESC_FRAMEANIM) ~= 0 or
							(
								ffi.cast(I32, desc + 52)[0] ~= 0 and
								shdr.animblocks_count == 0
							)
						then
							usable = false

							break
						end

						anims[b + 1] = desc
					end

					if usable then
						local first = anims[1]
						local frames = ffi.cast(I32, first + 16)[0]
						local fps = ffi.cast(F32, first + 8)[0]
						local group_size = {math.max(seq_i32[17], 1), math.max(seq_i32[18], 1)}
						local param_names = {}
						local param_start = {}
						local param_end = {}

						for axis = 1, 2 do
							local param = seq_i32[18 + axis]
							param_names[axis] = param >= 0 and source.pose_parameter_names[param] or nil
							param_start[axis] = ffi.cast(F32, seq + 84)[axis - 1]
							param_end[axis] = ffi.cast(F32, seq + 92)[axis - 1]

							if param_names[axis] and not skeleton.PoseParameterRanges[param_names[axis]] then
								skeleton.PoseParameterNames[#skeleton.PoseParameterNames + 1] = param_names[axis]
								skeleton.PoseParameterRanges[param_names[axis]] = {param_start[axis], param_end[axis]}
							end
						end

						skeleton:AddClip{
							Name = name,
							Duration = frames > 1 and fps > 0 and (frames - 1) / fps or 0,
							Loop = band(flags, SEQ_LOOPING) ~= 0,
							Sample = sample_sequence,
							skeleton = skeleton,
							source = source,
							bone_map = bone_map,
							anims = anims,
							group_size = group_size,
							param_names = param_names,
							param_start = param_start,
							param_end = param_end,
						}
					end
				end
			end

			for _, include in ipairs(source.includes) do
				local ok, included = pcall(open_source, include)

				if ok then
					add_clips(included)
				else
					llog("%s includes %s, its animations are skipped: %s", source.path, include, included)
				end
			end
		end

		add_clips(main)
		return skeleton
	end
end

model_loader.AddModelDecoder("mdl", function(path, full_path, mesh_callback, physics_callback, skeleton_callback)
	local models = {}
	local companion_path = path

	if full_path:ends_with(".mdl") then
		full_path = full_path:sub(1, -#".mdl" - 1)
	end

	if companion_path:ends_with(".mdl") then
		companion_path = companion_path:sub(1, -#".mdl" - 1)
	end

	--utility.PushTimeWarning()
	local mdl = load_mdl(full_path)

	if pcall(find_file, companion_path, ".phy") then
		local solids = load_phy(companion_path)
		local children = {}
		local mass = 0
		local surface_property
		local center_of_mass = Vec3(0, 0, 0)
		local damping = 0
		local rotation_damping = 0

		for _, solid in ipairs(solids) do
			local weight = solid.mass or 1
			center_of_mass = center_of_mass + solid.mass_center * weight
			damping = damping + (solid.damping or 0) * weight
			rotation_damping = rotation_damping + (solid.rotation_damping or 0) * weight
			mass = mass + weight
			surface_property = surface_property or solid.surface_property
		end

		center_of_mass = center_of_mass / mass
		damping = damping / mass
		rotation_damping = rotation_damping / mass

		for _, solid in ipairs(solids) do
			for _, points in ipairs(solid.ledges) do
				local min = Vec3(math.huge, math.huge, math.huge)
				local max = Vec3(-math.huge, -math.huge, -math.huge)

				for _, point in ipairs(points) do
					min.x, min.y, min.z = math.min(min.x, point.x), math.min(min.y, point.y), math.min(min.z, point.z)
					max.x, max.y, max.z = math.max(max.x, point.x), math.max(max.y, point.y), math.max(max.z, point.z)
				end

				local center = (min + max) * 0.5

				for i, point in ipairs(points) do
					points[i] = point - center
				end

				local hull = convex_hull.Normalize(points)

				if hull then
					children[#children + 1] = {ConvexHull = hull, Position = center - center_of_mass}
				end
			end
		end

		if children[1] then
			physics_callback{
				children = children,
				mass = solids[1].mass and mass or mdl.mass,
				surface_property = surface_property,
				center_of_mass = center_of_mass,
				damping = damping,
				rotation_damping = rotation_damping,
				inertia = #solids == 1 and
					Vec3(solids[1].rotation_inertia.z, solids[1].rotation_inertia.y, solids[1].rotation_inertia.x) * (
						mass * PHY_TO_METERS * PHY_TO_METERS
					)
					or
					nil,
			}
		end
	end

	local skeleton = load_skeleton(full_path)

	if skeleton then skeleton_callback(skeleton) end

	if mdl.bodypart_count == 0 or not render.IsInitialized() then return models end

	local vvd = load_vvd(companion_path)
	local vtx = load_vtx(companion_path, mdl.version >= 49 and 33 or 25)

	--	utility.PopTimeWarning("model read", 0)
	--utility.PushTimeWarning()
	if _debug then tasks.Report("generating mesh") end

	for body_part_i, body_part in ipairs(vtx.body_parts) do
		for model_index, model_ in ipairs(body_part.models) do
			for lod_index, lod_model in ipairs(model_.model_lods) do
				if lod_model.meshes and lod_model.meshes[1] then
					local vertices = vvd.fixed_vertices_by_lod[lod_index] or vvd.vertices
					local copy = {}

					for i, v in ipairs(vertices) do
						copy[i] = {pos = v.pos:Copy(), normal = v.normal:Copy(), uv = v.uv:Copy()}
					end

					local skin

					if skeleton then
						skin = {
							BoneIndices = ffi.new("uint8_t[?]", #vertices * 4),
							BoneWeights = ffi.new("float[?]", #vertices * 4),
						}

						for i, v in ipairs(vertices) do
							if v.bone_count == 0 then skin.BoneWeights[(i - 1) * 4] = 1 end

							for k = 1, v.bone_count do
								skin.BoneIndices[(i - 1) * 4 + k - 1] = v.bone_ids[k]
								skin.BoneWeights[(i - 1) * 4 + k - 1] = v.bone_weights[k]
							end
						end
					end

					local model_info = mdl.bodypart_models[body_part_i][model_index]

					for model_i, mesh_data in ipairs(lod_model.meshes) do
						local mesh_info = model_info.meshes[model_i]
						local vertex_offset = model_info.vertex_start + mesh_info.vertex_offset

						if _debug then
							tasks.ReportProgress("generating mesh", #vtx.body_parts * #model_.model_lods * #lod_model.meshes)
						end

						tasks.Wait()
						local mesh = Polygon3D.New()
						mesh:SetVertices(copy)
						local indices = {}
						local index_i = 1

						for _, strip_group in ipairs(mesh_data.strip_groups) do
							for _, strip in ipairs(strip_group.strips) do
								-- Each strip uses a portion of the shared indices array
								-- indices_offset is 0-based, so add 1 for Lua 1-based array access
								for i = 1, strip.indices_count do
									local index = strip.indices[strip.indices_offset + i]
									-- The index value directly indexes into strip_group.vertices (1-based after +1 during read)
									local v = strip.vertices[index]

									if v then
										-- mesh_vertex_index is local to the mesh, which starts at vertex_offset
										indices[index_i] = v.mesh_vertex_index + vertex_offset + 1
										index_i = index_i + 1
									end
								end
							end
						end

						mesh:SetName(full_path)
						local material
						local path = mdl.materials[mesh_info.material + 1]

						if path then
							if path:find("/", nil, true) or path:find("\\", nil, true) then
								path = vfs.FindMixedCasePath("materials/" .. path .. ".vmt") or path
							else
								for _, dir in ipairs(mdl.texturedir) do
									local new_path = vfs.FindMixedCasePath(dir.path .. path .. ".vmt")

									if new_path then
										path = new_path

										break
									end
								end
							end

							material = Material.FromVMT(path)
						end

						mesh:BuildBoundingBox()
						mesh:Upload(indices)
						mesh.Skin = skin
						mesh_callback(mesh, material)
						list.insert(models, mesh)
					end
				end

				-- Only process first LOD per body part for highest quality
				break
			end
		end
	end

	--utility.PopTimeWarning("model generation", 0)
	return models
end)
