local ffi = require("ffi")
local buffer = require("string.buffer")
local clip_bank = {}
clip_bank.file_extensions = {"clips"}
local MAGIC = "GCLB"
local VERSION = 1
local HEADER_SIZE = 12
local POSE_SIZE = 7
local U32 = ffi.typeof("uint32_t[1]")
local U32_PTR = ffi.typeof("const uint32_t *")
local CHAR_PTR = ffi.typeof("const char *")
local FLOAT_PTR = ffi.typeof("const float *")

local function align4(n)
	return n + (4 - n % 4) % 4
end

function clip_bank.CanDecodeData(data)
	return data:sub(1, 4) == MAGIC
end

function clip_bank.Encode(bank)
	local bone_count = #bank.bone_names
	local clips = {}
	local float_count = bone_count * POSE_SIZE

	for i, clip in ipairs(bank.clips) do
		clips[i] = {
			name = clip.name,
			fps = clip.fps,
			frame_count = clip.frame_count,
			loop = clip.loop,
			offset = float_count,
		}
		float_count = float_count + clip.frame_count * bone_count * POSE_SIZE
	end

	local meta = buffer.encode{
		prefix = bank.prefix,
		bone_names = bank.bone_names,
		parents = bank.parents,
		clips = clips,
	}
	local out = buffer.new()
	out:put(MAGIC)
	out:put(ffi.string(U32(VERSION), 4))
	out:put(ffi.string(U32(#meta), 4))
	out:put(meta)
	out:put(string.rep("\0", align4(HEADER_SIZE + #meta) - HEADER_SIZE - #meta))
	out:put(ffi.string(bank.bind, bone_count * POSE_SIZE * 4))

	for i, clip in ipairs(bank.clips) do
		out:put(ffi.string(clip.frames, clip.frame_count * bone_count * POSE_SIZE * 4))
	end

	return out:get()
end

function clip_bank.Decode(data)
	if not clip_bank.CanDecodeData(data) then return nil, "not a clip bank" end

	local header = ffi.cast(U32_PTR, ffi.cast(CHAR_PTR, data) + 4)

	if header[0] ~= VERSION then
		return nil, "unsupported clip bank version " .. header[0]
	end

	local meta_size = header[1]
	local meta = buffer.decode(data:sub(HEADER_SIZE + 1, HEADER_SIZE + meta_size))
	local bone_count = #meta.bone_names
	local blob_start = align4(HEADER_SIZE + meta_size)
	local floats = ffi.cast(FLOAT_PTR, ffi.cast(CHAR_PTR, data) + blob_start)
	local bank = {
		source = data,
		prefix = meta.prefix,
		bone_names = meta.bone_names,
		parents = meta.parents,
		bind = floats,
		clips = {},
		clips_by_name = {},
	}
	local expected = bone_count * POSE_SIZE

	for i, clip in ipairs(meta.clips) do
		clip.frames = floats + clip.offset
		bank.clips[i] = clip
		bank.clips_by_name[clip.name] = clip
		expected = math.max(expected, clip.offset + clip.frame_count * bone_count * POSE_SIZE)
	end

	if blob_start + expected * 4 ~= #data then
		return nil, "clip bank size does not match its header"
	end

	return bank
end

return clip_bank
