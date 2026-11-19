local ffi = require("ffi")
local zstd = import("goluwa/codecs/zstd.lua")
local ktx2 = {}
ktx2.file_extensions = {"ktx2"}
ktx2.magic_headers = {"\xABKTX 20\xBB\r\n\x1A\n"}
ktx2.returns_blob = true
ktx2.thread_job = [[
	local input = ...
	local Buffer = import("goluwa/structs/buffer.lua")
	local ktx2 = import("goluwa/codecs/ktx2.lua")
	return ktx2.DecodeBuffer(Buffer.New(input, #input))
]]
local u32_ptr_t = ffi.typeof("const uint32_t *")
local bytes_t = ffi.typeof("uint8_t[?]")
local SUPERCOMPRESSION_NONE = 0
local SUPERCOMPRESSION_ZSTD = 2
-- vkFormat: engine format name, block width, block height, bytes per block
local FORMATS = {
	[37] = {"r8g8b8a8_unorm", 1, 1, 4},
	[43] = {"r8g8b8a8_srgb", 1, 1, 4},
	[97] = {"r16g16b16a16_sfloat", 1, 1, 8},
	[109] = {"r32g32b32a32_sfloat", 1, 1, 16},
	[131] = {"bc1_rgb_unorm_block", 4, 4, 8},
	[132] = {"bc1_rgb_srgb_block", 4, 4, 8},
	[133] = {"bc1_rgba_unorm_block", 4, 4, 8},
	[134] = {"bc1_rgba_srgb_block", 4, 4, 8},
	[135] = {"bc2_unorm_block", 4, 4, 16},
	[136] = {"bc2_srgb_block", 4, 4, 16},
	[137] = {"bc3_unorm_block", 4, 4, 16},
	[138] = {"bc3_srgb_block", 4, 4, 16},
	[139] = {"bc4_unorm_block", 4, 4, 8},
	[140] = {"bc4_snorm_block", 4, 4, 8},
	[141] = {"bc5_unorm_block", 4, 4, 16},
	[142] = {"bc5_snorm_block", 4, 4, 16},
	[143] = {"bc6h_ufloat_block", 4, 4, 16},
	[144] = {"bc6h_sfloat_block", 4, 4, 16},
	[145] = {"bc7_unorm_block", 4, 4, 16},
	[146] = {"bc7_srgb_block", 4, 4, 16},
}

local function u64(p, at)
	local w = ffi.cast(u32_ptr_t, p + at)
	return w[0] + w[1] * 4294967296
end

function ktx2.ReadHeader(p, size)
	p = ffi.cast("const uint8_t *", p)

	if size < 80 or ffi.string(p, 12) ~= ktx2.magic_headers[1] then
		error("not a ktx2 file", 2)
	end

	local h = ffi.cast(u32_ptr_t, p + 12)
	local vk_format = h[0]
	local format = FORMATS[vk_format]

	if not format then error("unsupported ktx2 vkFormat " .. vk_format, 2) end

	local header = {
		vk_format = vk_format,
		width = h[2],
		height = math.max(h[3], 1),
		depth = math.max(h[4], 1),
		layers = math.max(h[5], 1),
		faces = h[6],
		level_count = math.max(h[7], 1),
		supercompression = h[8],
		format = format[1],
		block_width = format[2],
		block_height = format[3],
		block_bytes = format[4],
		levels = {},
	}

	if header.layers ~= 1 or header.faces ~= 1 or header.depth ~= 1 then
		error("only single 2d ktx2 images are supported", 2)
	end

	if
		header.supercompression ~= SUPERCOMPRESSION_NONE and
		header.supercompression ~= SUPERCOMPRESSION_ZSTD
	then
		error("unsupported ktx2 supercompression scheme " .. header.supercompression, 2)
	end

	if 80 + header.level_count * 24 > size then
		error("truncated ktx2 level index", 2)
	end

	for i = 1, header.level_count do
		local at = 80 + (i - 1) * 24
		local w = math.max(1, math.floor(header.width / 2 ^ (i - 1)))
		local hh = math.max(1, math.floor(header.height / 2 ^ (i - 1)))
		header.levels[i] = {
			file_offset = u64(p, at),
			file_size = u64(p, at + 8),
			width = w,
			height = hh,
			size = math.ceil(w / format[2]) * math.ceil(hh / format[3]) * format[4],
		}
	end

	return header
end

function ktx2.ReadFileHeader(path)
	local vfs = import("goluwa/filesystem/vfs.lua")
	local file_path, offset = vfs.GetReadLocation(path)

	if not file_path then return nil, "could not find " .. path end

	local file = assert(io.open(file_path, "rb"))
	file:seek("set", offset)
	local head = file:read(80 + 24 * 16)
	file:close()
	return ktx2.ReadHeader(head, #head)
end

function ktx2.DecodeBuffer(input)
	local p = ffi.cast("const uint8_t *", input:GetBuffer())
	local size = input:GetSize()
	local header = ktx2.ReadHeader(p, size)
	local mip_info = {}
	local total = 0

	for i, level in ipairs(header.levels) do
		if level.file_offset + level.file_size > size then
			error("ktx2 level " .. i .. " is out of bounds")
		end

		mip_info[i] = {
			width = level.width,
			height = level.height,
			depth = 1,
			size = level.size,
			offset = total,
		}
		total = total + level.size
	end

	local data = bytes_t(total)

	for i, level in ipairs(header.levels) do
		local dst = data + mip_info[i].offset

		if header.supercompression == SUPERCOMPRESSION_ZSTD then
			local written = zstd.Decompress(p + level.file_offset, level.file_size, dst, level.size)

			if written ~= level.size then
				error(
					"ktx2 level " .. i .. " decompressed to " .. written .. " bytes, expected " .. level.size
				)
			end
		else
			if level.file_size ~= level.size then
				error("ktx2 level " .. i .. " has the wrong size")
			end

			ffi.copy(dst, p + level.file_offset, level.size)
		end
	end

	return {
		width = header.width,
		height = header.height,
		depth = 1,
		format = header.format,
		vulkan_format = header.format,
		mip_count = header.level_count,
		array_size = 1,
		is_cubemap = false,
		is_volume = false,
		is_compressed = header.block_width > 1,
		block_size = header.block_bytes,
		bytes_per_pixel = header.block_width == 1 and header.block_bytes or nil,
		mip_info = mip_info,
		data_size = total,
	},
	data
end

return ktx2
