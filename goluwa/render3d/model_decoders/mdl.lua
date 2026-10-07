local vmt_material = import("goluwa/source_engine/vmt_material.lua")
local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local tasks = import("goluwa/tasks.lua")
local thread_pool = import("goluwa/thread_pool.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local convex_hull = import("goluwa/physics/convex_hull.lua")
local render = import("goluwa/render/render.lua")
local vertex_math = import("goluwa/render3d/vertex_math.lua")
local mdl_codec = import("goluwa/codecs/mdl.lua")
local blob = import("goluwa/codecs/internal/blob.lua")
local R = vfs.GetAbsolutePath
local ffi = require("ffi")
local bit = require("bit")
local fs = import("goluwa/filesystem/fs.lua")
local Skeleton = import("goluwa/render3d/skeleton.lua")
local lod = import("goluwa/render3d/lod.lua")
local half_to_float = mdl_codec.HalfToFloat

local function find_file(path, ...)
	local extensions = {...}
	local ok, err
	local attempts = {}

	for _, ext in ipairs(extensions) do
		table.insert(attempts, path .. ext)
		ok, err = vfs.Open(path .. ext)

		if ok then return ok end
	end

	for _, ext in ipairs(extensions) do
		local found = vfs.FindMixedCasePath(path .. ext)

		if found then
			ok, err = vfs.Open(found)

			if ok then return ok end
		end
	end

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

local function read_file(path, ...)
	local file = find_file(path, ...)
	local data = file:ReadBytes(file:GetSize())
	file:Close()
	return data
end

local function remap_clamped(value, from_min, from_max, to_min, to_max)
	if from_min == from_max then return value >= from_max and to_max or to_min end

	return to_min + (
			to_max - to_min
		) * math.clamp((value - from_min) / (from_max - from_min), 0, 1)
end

local function run_flex_rules(flex, src, dest)
	local min, max = flex.ControllerMin, flex.ControllerMax

	for i = 0, flex.DescCount - 1 do
		dest[i] = 0
	end

	for _, rule in ipairs(flex.rules) do
		local stack = {}
		local k = 0
		local ops = rule.ops

		for j = 1, #ops, 2 do
			local op, arg = ops[j], ops[j + 1]

			if op == 1 then
				k = k + 1
				stack[k] = arg
			elseif op == 2 then
				k = k + 1
				stack[k] = src[arg]
			elseif op == 3 then
				k = k + 1
				stack[k] = dest[arg]
			elseif op == 4 then
				stack[k - 1] = stack[k - 1] + stack[k]
				k = k - 1
			elseif op == 5 then
				stack[k - 1] = stack[k - 1] - stack[k]
				k = k - 1
			elseif op == 6 then
				stack[k - 1] = stack[k - 1] * stack[k]
				k = k - 1
			elseif op == 7 then
				stack[k - 1] = stack[k] > 0.0001 and stack[k - 1] / stack[k] or 0
				k = k - 1
			elseif op == 8 then
				stack[k] = -stack[k]
			elseif op == 13 then
				stack[k - 1] = math.max(stack[k - 1], stack[k])
				k = k - 1
			elseif op == 14 then
				stack[k - 1] = math.min(stack[k - 1], stack[k])
				k = k - 1
			elseif op == 15 then
				k = k + 1
				stack[k] = remap_clamped(src[arg], -1, 0, 1, 0)
			elseif op == 16 then
				k = k + 1
				stack[k] = remap_clamped(src[arg], 0, 1, 0, 1)
			elseif op == 17 then
				local value = src[stack[k]]
				local a, b, c, d = stack[k - 4], stack[k - 3], stack[k - 2], stack[k - 1]

				if value <= a or value >= d then
					value = 0
				elseif value < b then
					value = remap_clamped(value, a, b, 0, 1)
				elseif value > c then
					value = remap_clamped(value, c, d, 1, 0)
				else
					value = 1
				end

				stack[k - 4] = value * src[arg]
				k = k - 4
			elseif op == 18 then
				local first = k - arg + 1

				for i = first + 1, k do
					stack[first] = stack[first] * stack[i]
				end

				k = first
			elseif op == 19 then
				local first = k - arg + 1
				local dominance = stack[first]

				for i = first + 1, k do
					dominance = dominance * stack[i]
				end

				stack[first - 1] = stack[first - 1] * (1 - dominance)
				k = k - arg
			elseif op == 20 or op == 21 then
				local close_v = remap_clamped(src[arg], min[arg + 1], max[arg + 1], 0, 1)
				local close_lid_controller = stack[k]
				local close = remap_clamped(
					src[close_lid_controller],
					min[close_lid_controller + 1],
					max[close_lid_controller + 1],
					0,
					1
				)
				local up_down_controller = stack[k - 2]
				local up_down = 0

				if up_down_controller >= 0 then
					up_down = remap_clamped(
						src[up_down_controller],
						min[up_down_controller + 1],
						max[up_down_controller + 1],
						-1,
						1
					)
				end

				if op == 20 then
					stack[k - 2] = up_down > 0 and (1 - up_down) * (1 - close_v) * close or (1 - close_v) * close
				else
					stack[k - 2] = up_down < 0 and (1 + up_down) * close_v * close or close_v * close
				end

				k = k - 2
			end
		end

		dest[rule.flex] = stack[1]
	end
end

local load_skeleton

do
	local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
	local U8 = ffi.typeof("const uint8_t*")
	local I16 = ffi.typeof("const int16_t*")
	local U16 = ffi.typeof("const uint16_t*")
	local I32 = ffi.typeof("const int32_t*")
	local U32 = ffi.typeof("const uint32_t*")
	local F32 = ffi.typeof("const float*")
	local SCALE = import("goluwa/source_engine/units.lua").meters
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
	local R = {{0, -1, 0}, {0, 0, 1}, {-1, 0, 0}}

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

	local function open_source(path)
		local key = path:lower()

		if sources[key] then return sources[key] end

		local buffer = find_file(path, ".mdl")
		local hdr = buffer:ReadStructure(mdl_codec.header_structure)
		buffer:SetPosition(0)
		local bytes = buffer:ReadBytes(buffer:GetSize())
		local data = ffi.new("uint8_t[?]", #bytes)
		ffi.copy(data, bytes, #bytes)
		local source = {path = path, header = hdr, data = data, blocks = {}}
		local bone_count = hdr.bone_count
		source.bone_names = {}
		source.bone_parents = {}
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

local copy_array
local job_source = [=[
	local input = ...
	local ffi = require("ffi")
	local mdl = import("goluwa/codecs/mdl.lua")
	local vvd = import("goluwa/codecs/vvd.lua")
	local vtx = import("goluwa/codecs/vtx.lua")
	local phy = import("goluwa/codecs/phy.lua")
	local blob = import("goluwa/codecs/internal/blob.lua")
	local source = import("goluwa/source_engine/units.lua")
	local convex_hull = import("goluwa/physics/convex_hull.lua")
	local vertex_math = import("goluwa/render3d/vertex_math.lua")
	local Vec3 = import("goluwa/structs/vec3.lua")
	local builder = blob.New()
	local mdl_meta, mdl_blob = assert(mdl.Decode(input.mdl))
	local result = {mdl = mdl_meta}

	if mdl_blob then result.mdl_offset = builder:Add(mdl_blob) end

	if input.phy then
		local solids = assert(phy.Decode(input.phy)).solids
		local children = {}
		local mass = 0
		local surface_property
		local center_of_mass = Vec3(0, 0, 0)
		local damping = 0
		local rotation_damping = 0

		for _, solid in ipairs(solids) do
			local weight = solid.mass or 1
			center_of_mass = center_of_mass + Vec3(solid.mass_center[1], solid.mass_center[2], solid.mass_center[3]) * weight
			damping = damping + (solid.damping or 0) * weight
			rotation_damping = rotation_damping + (solid.rotation_damping or 0) * weight
			mass = mass + weight
			surface_property = surface_property or solid.surface_property
		end

		center_of_mass = center_of_mass / mass
		damping = damping / mass
		rotation_damping = rotation_damping / mass

		for _, solid in ipairs(solids) do
			for _, flat in ipairs(solid.ledges) do
				local points = {}
				local min = Vec3(math.huge, math.huge, math.huge)
				local max = Vec3(-math.huge, -math.huge, -math.huge)

				for i = 1, #flat, 3 do
					local point = Vec3(flat[i], flat[i + 1], flat[i + 2])
					points[#points + 1] = point
					min.x, min.y, min.z = math.min(min.x, point.x), math.min(min.y, point.y), math.min(min.z, point.z)
					max.x, max.y, max.z = math.max(max.x, point.x), math.max(max.y, point.y), math.max(max.z, point.z)
				end

				local center = (min + max) * 0.5

				for i, point in ipairs(points) do
					points[i] = point - center
				end

				local hull = convex_hull.Normalize(points)

				if hull then
					local position = center - center_of_mass
					children[#children + 1] = {
						hull = convex_hull.ToPlain(hull),
						position = {position.x, position.y, position.z},
					}
				end
			end
		end

		if children[1] then
			local inertia

			if #solids == 1 then
				local ri = solids[1].rotation_inertia
				local k = mass * source.phy_to_meters * source.phy_to_meters
				inertia = {ri[3] * k, ri[2] * k, ri[1] * k}
			end

			result.physics = {
				children = children,
				mass = solids[1].mass and mass or mdl_meta.mass,
				surface_property = surface_property,
				center_of_mass = {center_of_mass.x, center_of_mass.y, center_of_mass.z},
				damping = damping,
				rotation_damping = rotation_damping,
				inertia = inertia,
			}
		end
	end

	if input.meshes and mdl_meta.bodypart_count > 0 then
		assert(input.vvd, input.vvd_error)
		assert(input.vtx, input.vtx_error)
		local vvd_meta, vertices = assert(vvd.Decode(input.vvd))
		local vtx_meta, vtx_blob = assert(vtx.Decode(input.vtx, mdl_meta.version >= 49 and 33 or 25))
		local vertex_count = vvd_meta.count
		local vertex_lods = vvd_meta.vertex_lods
		local skinned = mdl_meta.bone_count >= 2
		result.meshes = {}
		result.skins = {}
		-- the vertices of a lod are the ones the vvd fixups keep for it, in the order of the full array. the
		-- vtx ids of its meshes count from where the mesh starts in that smaller array
		local lod_vertex_sets = {}

		local function get_vertex_set(lod_index)
			local set = lod_vertex_sets[lod_index]

			if set then return set end

			local rank = ffi.new("uint32_t[?]", vertex_count + 1)
			local source = ffi.new("uint32_t[?]", math.max(vertex_count, 1))
			local count = 0

			for i = 0, vertex_count - 1 do
				rank[i] = count

				if vertex_lods[i] >= lod_index then
					source[count] = i
					count = count + 1
				end
			end

			rank[vertex_count] = count
			set = {rank = rank, source = source, count = count, same_as_full = count == vertex_count}
			lod_vertex_sets[lod_index] = set
			return set
		end

		for body_part_i, body_part in ipairs(vtx_meta.body_parts) do
			for model_i, model in ipairs(body_part.models) do
				local model_info = mdl_meta.bodypart_models[body_part_i][model_i]

				for lod_i, lod in ipairs(model.lods) do
					-- a negative switch point marks the shadow only lod at the end
					if lod.meshes[1] and (lod_i == 1 or lod.switch_point >= 0) then
						local lod_index = lod_i - 1
						local set = get_vertex_set(lod_index)
						local set_count = set.count
						local index_size = set_count > 65535 and 4 or 2
						local index_ctype = index_size == 4 and "uint32_t" or "uint16_t"
						local skin_key

						if skinned then
							skin_key = body_part_i .. ":" .. model_i .. ":" .. (set.same_as_full and 0 or lod_index)

							if not result.skins[skin_key] then
								local bone_indices = ffi.new("uint8_t[?]", set_count * 4)
								local bone_weights = ffi.new("float[?]", set_count * 4)

								for i = 0, set_count - 1 do
									local v = vertices[set.source[i]]

									if v.bone_count == 0 then bone_weights[i * 4] = 1 end

									for k = 0, math.min(v.bone_count, 3) - 1 do
										bone_indices[i * 4 + k] = v.bone_ids[k]
										bone_weights[i * 4 + k] = v.bone_weights[k]
									end
								end

								result.skins[skin_key] = {
									bone_indices = builder:Add(bone_indices),
									bone_weights = builder:Add(bone_weights),
									vertex_count = set_count,
									flexes = set.same_as_full,
								}
							end
						end

						local base_packed = vertex_math.VertexType(set_count)

						for i = 0, set_count - 1 do
							local v, p = vertices[set.source[i]], base_packed[i]

							for k = 0, 2 do
								p.position[k] = v.pos[k]
								p.normal[k] = v.normal[k]
							end

							p.uv[0], p.uv[1] = v.uv[0], v.uv[1]
						end

						local packed_size = ffi.sizeof(base_packed[0]) * set_count

						for mesh_i, mesh_data in ipairs(lod.meshes) do
							local mesh_info = model_info.meshes[mesh_i]
							local index_count = mesh_data.count

							if index_count > 0 or lod_i == 1 then
								local vertex_offset = set.rank[model_info.vertex_start + mesh_info.vertex_offset]
								local ids = ffi.cast("const uint16_t *", vtx_blob + mesh_data.offset)
								local indices = ffi.new(index_ctype .. "[?]", math.max(index_count, 1))

								for i = 0, index_count - 1 do
									indices[i] = ids[i] + vertex_offset
								end

								local packed = vertex_math.VertexType(set_count)
								ffi.copy(packed, base_packed, packed_size)
								vertex_math.BuildTangents(packed, set_count, indices, index_count)
								result.meshes[#result.meshes + 1] = {
									body_part = body_part_i,
									model = model_i,
									lod = lod_index,
									switch_point = lod.switch_point,
									skin = skin_key,
									material = mesh_info.material,
									vertex_count = set_count,
									index_size = index_size,
									index_count = index_count,
									vertex_offset = builder:Add(packed),
									index_offset = builder:Add(indices, index_count * index_size),
								}
							end
						end
					end
				end
			end
		end
	end

	return result, builder:Finish()
]=]

do
	local array_types = {
		uint8_t = ffi.typeof("uint8_t[?]"),
		uint16_t = ffi.typeof("uint16_t[?]"),
		uint32_t = ffi.typeof("uint32_t[?]"),
		float = ffi.typeof("float[?]"),
	}
	local element_sizes = {uint8_t = 1, uint16_t = 2, uint32_t = 4, float = 4}

	function copy_array(blob_table, ctype, offset, count)
		local array = array_types[ctype](math.max(count, 1))

		if count > 0 then
			ffi.copy(array, blob_table.ptr + offset, count * element_sizes[ctype])
		end

		return array
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

	local input = {meshes = render.IsInitialized(), mdl = read_file(full_path, ".mdl")}
	local size = #input.mdl
	local ok, phy_data = pcall(read_file, companion_path, ".phy")

	if ok and #phy_data > 0 then
		input.phy = phy_data
		size = size + #phy_data
	end

	if input.meshes then
		ok, input.vvd = pcall(read_file, companion_path, ".vvd")

		if ok then
			size = size + #input.vvd
		else
			input.vvd, input.vvd_error = nil, input.vvd
		end

		ok, input.vtx = pcall(read_file, companion_path, ".dx90.vtx", ".dx80.vtx", ".sw.vtx")

		if ok then
			size = size + #input.vtx
		else
			input.vtx, input.vtx_error = nil, input.vtx
		end
	end

	local meta, blob_table = thread_pool.Run(job_source, input, size):Await()
	local mdl = meta.mdl

	for _, model_flexes in ipairs(mdl.bodypart_models) do
		for _, model in ipairs(model_flexes) do
			for _, flex in ipairs(model.flexes) do
				flex.Indices = copy_array(blob_table, "uint32_t", meta.mdl_offset + flex.indices_offset, flex.Count)
				flex.Deltas = copy_array(blob_table, "float", meta.mdl_offset + flex.deltas_offset, flex.Count * 6)
				flex.Sides = copy_array(blob_table, "uint8_t", meta.mdl_offset + flex.sides_offset, flex.Count)
			end
		end
	end

	if meta.physics then
		local physics = meta.physics
		local children = {}

		for i, child in ipairs(physics.children) do
			children[i] = {
				ConvexHull = convex_hull.FromPlain(child.hull),
				Position = Vec3(child.position[1], child.position[2], child.position[3]),
			}
		end

		physics_callback{
			children = children,
			mass = physics.mass,
			surface_property = physics.surface_property,
			center_of_mass = Vec3(physics.center_of_mass[1], physics.center_of_mass[2], physics.center_of_mass[3]),
			damping = physics.damping,
			rotation_damping = physics.rotation_damping,
			inertia = physics.inertia and
				Vec3(physics.inertia[1], physics.inertia[2], physics.inertia[3]) or
				nil,
		}
	end

	local skeleton = load_skeleton(full_path)

	if skeleton then
		if mdl.flex then mdl.flex.Compute = run_flex_rules end

		skeleton.Flex = mdl.flex
		skeleton_callback(skeleton)
	end

	if not meta.meshes then return models end

	local skins = {}

	for _, mesh_info in ipairs(meta.meshes) do
		local skin

		if skeleton then
			skin = skins[mesh_info.skin]

			if not skin then
				local skin_info = meta.skins[mesh_info.skin]
				local count = skin_info.vertex_count
				skin = {
					BoneIndices = copy_array(blob_table, "uint8_t", skin_info.bone_indices, count * 4),
					BoneWeights = copy_array(blob_table, "float", skin_info.bone_weights, count * 4),
					Flexes = skin_info.flexes and
						mdl.bodypart_models[mesh_info.body_part][mesh_info.model].flexes or
						{},
				}
				skins[mesh_info.skin] = skin
			end
		end

		tasks.Wait()
		local mesh = Polygon3D.New()
		local vertex_count = mesh_info.vertex_count
		local ctype = mesh_info.index_size == 4 and "uint32_t" or "uint16_t"
		local vertices = vertex_math.VertexType(vertex_count)
		ffi.copy(
			vertices,
			blob_table.ptr + mesh_info.vertex_offset,
			vertex_count * ffi.sizeof(vertices[0])
		)
		local indices = copy_array(blob_table, ctype, mesh_info.index_offset, mesh_info.index_count)
		mesh:UploadVertexArray(vertices, vertex_count, indices, mesh_info.index_count, true)
		mesh:SetName(full_path)
		mesh:SetLODLevel(mesh_info.lod)
		mesh:SetLODDistance(mesh_info.switch_point * lod.SOURCE_SWITCH_TO_RADII)
		local material
		local material_path = mdl.materials[mesh_info.material + 1]

		if material_path then
			if material_path:find("/", nil, true) or material_path:find("\\", nil, true) then
				material_path = vfs.FindMixedCasePath("materials/" .. material_path .. ".vmt") or material_path
			else
				for _, dir in ipairs(mdl.texturedir) do
					local new_path = vfs.FindMixedCasePath(dir.path .. material_path .. ".vmt")

					if new_path then
						material_path = new_path

						break
					end
				end
			end

			material = vmt_material.FromVMT(material_path)
		end

		mesh.Skin = skin
		mesh_callback(mesh, material)
		list.insert(models, mesh)
	end

	return models
end)
