local ffi = require("ffi")
local lz4 = import("goluwa/codecs/lz4.lua")
local vtex_c = {}
vtex_c.file_extensions = {"vtex_c"}
vtex_c.returns_blob = true
local u8_t = ffi.typeof("const uint8_t *")
local u16_t = ffi.typeof("const uint16_t *")
local u32_t = ffi.typeof("const uint32_t *")
local f32_t = ffi.typeof("const float *")
local FORMAT = {
	[1] = {vulkan = "bc1_rgba_unorm_block", block = 8},
	[2] = {vulkan = "bc3_unorm_block", block = 16},
	[3] = {vulkan = "r8_unorm", pixel = 1},
	[4] = {vulkan = "r8g8b8a8_unorm", pixel = 4},
	[8] = {vulkan = "r16_sfloat", pixel = 2},
	[9] = {vulkan = "r16g16_sfloat", pixel = 4},
	[10] = {vulkan = "r16g16b16a16_sfloat", pixel = 8},
	[11] = {vulkan = "r32_sfloat", pixel = 4},
	[14] = {vulkan = "r32g32b32a32_sfloat", pixel = 16},
	[19] = {vulkan = "bc6h_ufloat_block", block = 16},
	[20] = {vulkan = "bc7_unorm_block", block = 16},
	[21] = {vulkan = "bc5_unorm_block", block = 16},
	[27] = {vulkan = "bc4_unorm_block", block = 8},
	[28] = {vulkan = "b8g8r8a8_unorm", pixel = 4},
	[32] = {vulkan = "r8_unorm", pixel = 1},
	[33] = {vulkan = "r8_unorm", pixel = 1},
}
local FLAG_CUBE = 0x4
local FLAG_VOLUME = 0x20
local EXTRA_COMPRESSED_MIP_SIZE = 4

local function mip_size(info, width, height, depth)
	if info.block then
		return math.max(1, math.floor((width + 3) / 4)) * math.max(1, math.floor((height + 3) / 4)) * depth * info.block
	end

	return width * height * depth * info.pixel
end

function vtex_c.DecodeBuffer(buffer)
	local src = buffer:GetBuffer()
	local total = buffer:GetSize()
	local header = ffi.cast(u32_t, src)
	local block_offset, block_count = header[2], header[3]
	local data_block

	for i = 0, block_count - 1 do
		local p = 8 + block_offset + i * 12

		if ffi.string(src + p, 4) == "DATA" then
			data_block = {
				offset = p + 4 + ffi.cast(u32_t, src + p + 4)[0],
				size = ffi.cast(u32_t, src + p + 8)[0],
			}
		end
	end

	if not data_block then return nil, "vtex_c has no DATA block" end

	local d = src + data_block.offset
	local version = ffi.cast(u16_t, d)[0]

	if version ~= 1 then return nil, "unknown vtex version " .. version end

	local flags = ffi.cast(u16_t, d + 2)[0]
	local refl = ffi.cast(f32_t, d + 4)
	local width, height = ffi.cast(u16_t, d + 20)[0], ffi.cast(u16_t, d + 22)[0]
	local depth = ffi.cast(u16_t, d + 24)[0]
	local format = d[26]
	local mip_count = d[27]
	local info = FORMAT[format]

	if not info then return nil, "unsupported vtex format " .. format end

	local extra_offset, extra_count = ffi.cast(u32_t, d + 32)[0], ffi.cast(u32_t, d + 36)[0]
	local compressed_sizes, compression

	for i = 0, extra_count - 1 do
		local entry_pos = 32 + extra_offset + i * 12
		local etype = ffi.cast(u32_t, d + entry_pos)[0]
		local eoff = ffi.cast(u32_t, d + entry_pos + 4)[0]
		local data = d + entry_pos + 4 + eoff

		if etype == EXTRA_COMPRESSED_MIP_SIZE then
			compression = ffi.cast(u32_t, data)[0]
			local sizes_offset = ffi.cast(u32_t, data + 4)[0]
			local count = ffi.cast(u32_t, data + 8)[0]
			local sizes = ffi.cast(u32_t, data + 4 + sizes_offset)
			compressed_sizes = {}

			for m = 0, count - 1 do
				compressed_sizes[m] = sizes[m]
			end
		end
	end

	if compression == 2 then
		return nil, "zstd compressed vtex mips are not supported"
	end

	local faces = bit.band(flags, FLAG_CUBE) ~= 0 and 6 or 1
	local is_volume = bit.band(flags, FLAG_VOLUME) ~= 0
	local mips = {}
	local out_size = 0

	for m = 0, mip_count - 1 do
		local w, h = math.max(1, bit.rshift(width, m)), math.max(1, bit.rshift(height, m))
		local dp = is_volume and math.max(1, bit.rshift(depth, m)) or depth
		local size = mip_size(info, w, h, dp * faces)
		mips[m] = {width = w, height = h, depth = dp * faces, size = size, offset = out_size}
		out_size = out_size + size
	end

	local out = ffi.new("uint8_t[?]", out_size)
	local read_pos = data_block.offset + data_block.size

	for m = mip_count - 1, 0, -1 do
		local mip = mips[m]
		local stored = mip.size
		local csize = compressed_sizes and compressed_sizes[m]

		if read_pos + (csize and csize < mip.size and csize or mip.size) > total then
			return nil,
			"vtex_c mip " .. m .. " is out of bounds (format " .. format .. ", " .. width .. "x" .. height .. ")"
		end

		if compression == 1 and csize and csize < mip.size then
			ffi.copy(
				out + mip.offset,
				lz4.DecodeBlock(src, read_pos, read_pos + csize, mip.size),
				mip.size
			)
			stored = csize
		else
			ffi.copy(out + mip.offset, src + read_pos, mip.size)
		end

		read_pos = read_pos + stored
	end

	local mip_info = {}

	for m = 0, mip_count - 1 do
		mip_info[m + 1] = mips[m]
	end

	return {
		width = width,
		height = height,
		depth = depth,
		vulkan_format = info.vulkan,
		mip_count = mip_count,
		frames = 1,
		is_compressed = info.block ~= nil,
		block_size = info.block,
		bytes_per_pixel = info.pixel,
		mip_info = mip_info,
		data_size = out_size,
		frame_stride = out_size,
		reflectivity = {refl[0], refl[1], refl[2]},
		vtex_format = format,
	},
	out
end

return vtex_c
