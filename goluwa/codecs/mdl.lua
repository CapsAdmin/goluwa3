local ffi = require("ffi")
local bit = require("bit")
local file_path = import("goluwa/filesystem/path.lua")
local source = import("goluwa/source_engine/units.lua")
local blob = import("goluwa/codecs/internal/blob.lua")
local mdl = {}
mdl.file_extensions = {"mdl"}
mdl.magic_headers = {"IDST"}
mdl.returns_blob = true
local scale = source.meters
local header = [[
	string id[4]; // Model format ID, such as "IDST" (0x49 0x44 0x53 0x54)
	int version;
	int checksum;
	char name[64];

	int file_size;


	vec3 eye_position;
	vec3 illumination_position;
	vec3 hull_min;
	vec3 hull_max;
	vec3 view_bbmin;
	vec3 view_bbmax;

	int flags;

	/*
	 * After this point, the header contains many references to offsets
	 * within the MDL file and the number of items at those offsets.
	 *
	 * Offsets are from the very beginning of the file.
	 *
	 * Note that indexes/counts are not always paired and ordered consistently.
	 */

	int bone_count;
	int bone_offset;

	int bonecontroller_count;
	int bonecontroller_offset;

	int hitbox_count;
	int hitbox_offset;

	int localanim_count;
	int localanim_offset;

	int localseq_count;
	int localseq_offset;

	int activitylistversion;
	int eventsindexed;

	int material_count;
	int material_offset;

	int texturedir_count;
	int texturedir_offset;

	int skinreference_count;
	int skinrfamily_count;
	int skinreference_offset;

	int bodypart_count;
	int bodypart_offset;

	int attachment_count;
	int attachment_offset;

	int localnode_count;
	int localnode_offset;
	int localnode_name_offset;

	int flexdesc_count;
	int flexdesc_offset;

	int flexcontroller_count;
	int flexcontroller_offset;

	int flexrules_count;
	int flexrules_offset;

	int ikchain_count;
	int ikchain_offset;

	int mouths_count;
	int mouths_offset;

	int localposeparam_count;
	int localposeparam_offset;

	/*
	 * For anyone trying to follow along, as of this writing,
	 * the next "render2dprop_offset" value is at position 0x0134 (308)
	 * from the start of the file.
	 */

	int render2dprop_offset;

	int keyvalue_offset;
	int keyvalue_size;

	int iklock_count;
	int iklock_offset;


	float mass;
	int contents;


	int includemodel_count;
	int includemodel_offset;

	int virtualModel;

	int animblocks_name_offset;
	int animblocks_count;
	int animblocks_offset;

	int animblockModel;

	int bonetablename_offset;

	int vertex_base;
	int offset_base;

	byte directionaldotproduct;

	byte rootLod;

	byte numAllowedRootLods;

	byte unused;
	int unused;

	int flexcontrollerui_count;
	int flexcontrollerui_offset;

	/**
	 * Offset for additional header information.
	 * May be zero if not present, or also 408 if it immediately
	 * follows this studiohdr_t
	 */
	int studiohdr2index;

	int unused;

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
local EYEBALL_SIZE = 172
local BONE_SIZE = 216
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
		hull_min = {header.hull_min[0], header.hull_min[1], header.hull_min[2]},
		hull_max = {header.hull_max[0], header.hull_max[1], header.hull_max[2]},
		view_bbmin = {header.view_bbmin[0], header.view_bbmin[1], header.view_bbmin[2]},
		view_bbmax = {header.view_bbmax[0], header.view_bbmax[1], header.view_bbmax[2]},
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

	local eye_bone_count = 0

	for bodypart_i = 1, header.bodypart_count do
		local bodypart_pos = header.bodypart_offset + (bodypart_i - 1) * 16
		local model_count = i32(bodypart_pos + 4)
		local models_pos = bodypart_pos + i32(bodypart_pos + 12)
		local models = {}

		for model_i = 1, model_count do
			local model_pos = models_pos + (model_i - 1) * 148
			local mesh_count = i32(model_pos + 72)
			local meshes_pos = model_pos + i32(model_pos + 76)
			local model = {
				vertex_start = i32(model_pos + 84) / 48,
				meshes = {},
				flexes = {},
				eyeballs = {},
			}
			local eyeballs_pos = model_pos + i32(model_pos + 104)

			for eye_i = 1, i32(model_pos + 100) do
				local eye_pos = eyeballs_pos + (eye_i - 1) * EYEBALL_SIZE
				local bone_pos = header.bone_offset + i32(eye_pos + 4) * BONE_SIZE
				local m = {}

				for k = 0, 11 do
					m[k] = f32(bone_pos + 96 + k * 4)
				end

				local function to_model(x, y, z, translate)
					local bx = m[0] * x + m[4] * y + m[8] * z
					local by = m[1] * x + m[5] * y + m[9] * z
					local bz = m[2] * x + m[6] * y + m[10] * z

					if translate then
						bx = bx - (m[0] * m[3] + m[4] * m[7] + m[8] * m[11])
						by = by - (m[1] * m[3] + m[5] * m[7] + m[9] * m[11])
						bz = bz - (m[2] * m[3] + m[6] * m[7] + m[10] * m[11])
					end

					return -by, bz, -bx
				end

				local ox, oy, oz = to_model(f32(eye_pos + 8), f32(eye_pos + 12), f32(eye_pos + 16), true)
				local ux, uy, uz = to_model(f32(eye_pos + 28), f32(eye_pos + 32), f32(eye_pos + 36))
				local fx, fy, fz = to_model(f32(eye_pos + 40), f32(eye_pos + 44), f32(eye_pos + 48))
				model.eyeballs[eye_i] = {
					bone = i32(eye_pos + 4),
					virtual_bone = header.bone_count + eye_bone_count,
					material = i32(eye_pos + 52),
					radius = f32(eye_pos + 24) * scale,
					iris_scale = f32(eye_pos + 60),
					origin = {ox * scale, oy * scale, oz * scale},
					up = {ux, uy, uz},
					forward = {fx, fy, fz},
					upper_descs = {i32(eye_pos + 68), i32(eye_pos + 72), i32(eye_pos + 76)},
					lower_descs = {i32(eye_pos + 80), i32(eye_pos + 84), i32(eye_pos + 88)},
					upper_targets = {f32(eye_pos + 92), f32(eye_pos + 96), f32(eye_pos + 100)},
					lower_targets = {f32(eye_pos + 104), f32(eye_pos + 108), f32(eye_pos + 112)},
					upper_lid_desc = i32(eye_pos + 116),
					lower_lid_desc = i32(eye_pos + 120),
				}
				eye_bone_count = eye_bone_count + 1
			end

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
