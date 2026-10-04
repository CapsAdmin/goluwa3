local ffi = require("ffi")
local bit = require("bit")
local file_path = import("goluwa/filesystem/path.lua")
local source = import("goluwa/codecs/internal/source.lua")
local blob = import("goluwa/codecs/internal/blob.lua")
local mdl = library()
mdl.file_extensions = {"mdl"}
mdl.magic_headers = {"IDST"}
mdl.returns_blob = true
local scale = source.meters
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
mdl.header_structure = header
local header_t
local header_ptr_t

do
	local body = header:gsub("//[^\n]*", ""):gsub("/%*.-%*/", "")
	local fields = {}
	local used = {}

	for statement in body:gmatch("[^;]+") do
		statement = statement:gsub("^%s+", ""):gsub("%s+$", "")

		if statement ~= "" then
			local ctype, name, count = statement:match("^(%S+)%s+([%w_]+)%s*%[?(%d*)%]?$")
			local map = {
				string = "char",
				long = "int32_t",
				int = "int32_t",
				byte = "uint8_t",
				float = "float",
				char = "char",
			}

			if ctype == "vec3" then ctype, count = "float", "3" end

			used[name] = (used[name] or 0) + 1

			if used[name] > 1 then name = name .. used[name] end

			fields[#fields + 1] = map[ctype or
				""] and
				(
					map[ctype] .. " " .. name .. (
						count ~= "" and
						(
							"[" .. count .. "]"
						)
						or
						""
					) .. ";"
				)
				or
				(
					ctype and
					(
						ctype .. " " .. name .. (
							count ~= "" and
							(
								"[" .. count .. "]"
							)
							or
							""
						) .. ";"
					)
				)
		end
	end

	header_t = ffi.typeof("struct __attribute__((packed)) {" .. table.concat(fields, "\n") .. "}")
	header_ptr_t = ffi.typeof("const $ *", header_t)
end

local function half_to_float(h)
	local sign = h >= 0x8000 and -1 or 1
	local exponent = bit.band(bit.rshift(h, 10), 0x1f)
	local mantissa = bit.band(h, 0x3ff)

	if exponent == 0 then return sign * mantissa * 2 ^ -24 end

	if exponent == 31 then return sign * math.huge end

	return sign * (1 + mantissa / 1024) * 2 ^ (exponent - 15)
end

mdl.HalfToFloat = half_to_float
local VertAnim = ffi.typeof(
	"const struct { uint16_t index; uint8_t speed; uint8_t side; uint16_t delta[3]; uint16_t normal_delta[3]; } *"
)
local VertAnimWrinkle = ffi.typeof(
	"const struct { uint16_t index; uint8_t speed; uint8_t side; uint16_t delta[3]; uint16_t normal_delta[3]; int16_t wrinkle; } *"
)
local int32_ptr_t = ffi.typeof("const int32_t *")
local float_ptr_t = ffi.typeof("const float *")
local uint8_ptr_t = ffi.typeof("const uint8_t *")
local VERT_ANIM_SIZE = 16
local VERT_ANIM_WRINKLE_SIZE = 18

function mdl.Decode(str)
	if str:sub(1, 4) ~= "IDST" then return nil, "not an mdl file" end

	if #str < ffi.sizeof(header_t) then return nil, "mdl header is truncated" end

	local length = #str
	local base = ffi.cast(uint8_ptr_t, str)

	local function check(offset, size)
		if offset < 0 or size < 0 or offset + size > length then
			error("mdl data is out of range", 3)
		end
	end

	local function i32(offset)
		check(offset, 4)
		return ffi.cast(int32_ptr_t, base + offset)[0]
	end

	local function f32(offset)
		check(offset, 4)
		return ffi.cast(float_ptr_t, base + offset)[0]
	end

	local function cstring(offset)
		check(offset, 1)
		local stop = offset

		while stop < length and base[stop] ~= 0 do
			stop = stop + 1
		end

		return ffi.string(base + offset, stop - offset)
	end

	local builder = blob.New()
	local header = ffi.cast(header_ptr_t, base)[0]
	local meta = {
		version = header.version,
		name = "models/" .. ffi.string(header.name, 64):remove_padding():gsub("\\", "/"),
		mass = header.mass,
		bone_count = header.bone_count,
		bodypart_count = header.bodypart_count,
		materials = {},
		texturedir = {},
		bodypart_models = {},
	}

	if
		header.material_count > 0 and
		header.material_offset > 0 and
		header.material_offset < length
	then
		for i = 1, header.material_count do
			local material_pos = header.material_offset + (i - 1) * 64
			local offset = i32(material_pos)

			if offset > 0 and material_pos + offset < length then
				local mat = file_path.FixPathSlashes(cstring(material_pos + offset))

				if mat ~= "" and not mat:ends_with("/") then meta.materials[i] = mat end
			end
		end
	end

	for i = 1, header.texturedir_count do
		local offset = i32(header.texturedir_offset + (i - 1) * 4)
		meta.texturedir[i] = {path = "materials/" .. file_path.FixPathSlashes(cstring(offset))}
	end

	for bodypart_i = 1, header.bodypart_count do
		local bodypart_pos = header.bodypart_offset + (bodypart_i - 1) * 16
		local model_count = i32(bodypart_pos + 4)
		local models_pos = bodypart_pos + i32(bodypart_pos + 12)
		local models = {}

		for model_i = 1, model_count do
			local model_pos = models_pos + (model_i - 1) * 148
			local mesh_count = i32(model_pos + 72)
			local meshes_pos = model_pos + i32(model_pos + 76)
			local model = {vertex_start = i32(model_pos + 84) / 48, meshes = {}, flexes = {}}

			for mesh_i = 1, mesh_count do
				local mesh_pos = meshes_pos + (mesh_i - 1) * 116
				local material = i32(mesh_pos)
				local vertex_offset = i32(mesh_pos + 12)
				local flex_count = i32(mesh_pos + 16)
				local flexes_pos = mesh_pos + i32(mesh_pos + 20)
				model.meshes[mesh_i] = {material = material, vertex_offset = vertex_offset}

				for flex_i = 1, flex_count do
					local flex_pos = flexes_pos + (flex_i - 1) * 60
					local desc = i32(flex_pos)
					local t0, t1, t2, t3 = f32(flex_pos + 4), f32(flex_pos + 8), f32(flex_pos + 12), f32(flex_pos + 16)
					local count = i32(flex_pos + 20)
					local data_pos = flex_pos + i32(flex_pos + 24)
					local pair = i32(flex_pos + 28)
					check(flex_pos + 32, 1)
					local wrinkle = base[flex_pos + 32] == 1
					check(data_pos, count * (wrinkle and VERT_ANIM_WRINKLE_SIZE or VERT_ANIM_SIZE))
					local anims = ffi.cast(wrinkle and VertAnimWrinkle or VertAnim, base + data_pos)
					local indices = ffi.new("uint32_t[?]", count)
					local deltas = ffi.new("float[?]", count * 6)
					local sides = ffi.new("uint8_t[?]", count)
					local first = model.vertex_start + vertex_offset

					for i = 0, count - 1 do
						local anim = anims[i]
						local o = i * 6
						local dx, dy, dz = half_to_float(anim.delta[0]),
						half_to_float(anim.delta[1]),
						half_to_float(anim.delta[2])
						local nx, ny, nz = half_to_float(anim.normal_delta[0]),
						half_to_float(anim.normal_delta[1]),
						half_to_float(anim.normal_delta[2])
						indices[i] = first + anim.index
						sides[i] = anim.side
						deltas[o], deltas[o + 1], deltas[o + 2] = -dy * scale, dz * scale, -dx * scale
						deltas[o + 3], deltas[o + 4], deltas[o + 5] = -ny, nz, -nx
					end

					model.flexes[#model.flexes + 1] = {
						Desc = desc,
						Pair = pair,
						Targets = {t0, t1, t2, t3},
						Count = count,
						indices_offset = builder:Add(indices, count * 4),
						deltas_offset = builder:Add(deltas, count * 24),
						sides_offset = builder:Add(sides, count),
					}
				end
			end

			models[model_i] = model
		end

		meta.bodypart_models[bodypart_i] = models
	end

	if header.flexcontroller_count > 0 then
		local flex = {
			ControllerNames = {},
			ControllerMin = {},
			ControllerMax = {},
			DescNames = {},
			DescCount = header.flexdesc_count,
			rules = {},
		}

		for i = 1, header.flexcontroller_count do
			local pos = header.flexcontroller_offset + (i - 1) * 20
			local name_offset = i32(pos + 4)
			flex.ControllerNames[i] = name_offset == 0 and "" or cstring(pos + name_offset)
			flex.ControllerMin[i] = f32(pos + 12)
			flex.ControllerMax[i] = f32(pos + 16)
		end

		for i = 1, header.flexdesc_count do
			local pos = header.flexdesc_offset + (i - 1) * 4
			local name_offset = i32(pos)
			flex.DescNames[i] = name_offset == 0 and "" or cstring(pos + name_offset)
		end

		for i = 1, header.flexrules_count do
			local pos = header.flexrules_offset + (i - 1) * 12
			local rule = {flex = i32(pos), ops = {}}
			local op_count = i32(pos + 4)
			local ops_pos = pos + i32(pos + 8)

			for j = 0, op_count - 1 do
				local op = i32(ops_pos + j * 8)
				rule.ops[#rule.ops + 1] = op
				rule.ops[#rule.ops + 1] = op == 1 and f32(ops_pos + j * 8 + 4) or i32(ops_pos + j * 8 + 4)
			end

			flex.rules[i] = rule
		end

		meta.flex = flex
	end

	return meta, builder:Finish()
end

return mdl
