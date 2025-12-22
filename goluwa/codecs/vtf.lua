-- VTF (Valve Texture Format) decoder for LuaJIT
-- Decodes VTF textures, returning compressed data as-is for GPU upload (like DDS decoder)
-- Supports DXT1/3/5, RGBA8888, RGB888, BGR888, BGRA8888, and other common formats
local ffi = require("ffi")
local bit = require("bit")
local Buffer = require("structs.buffer")
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
-- VTF image format enum
local VTF_IMAGE_FORMAT = {
	RGBA8888 = 0,
	ABGR8888 = 1,
	RGB888 = 2,
	BGR888 = 3,
	RGB565 = 4,
	I8 = 5,
	IA88 = 6,
	P8 = 7,
	A8 = 8,
	RGB888_BLUESCREEN = 9,
	BGR888_BLUESCREEN = 10,
	ARGB8888 = 11,
	BGRA8888 = 12,
	DXT1 = 13,
	DXT3 = 14,
	DXT5 = 15,
	BGRX8888 = 16,
	BGR565 = 17,
	BGRX5551 = 18,
	BGRA4444 = 19,
	DXT1_ONEBITALPHA = 20,
	BGRA5551 = 21,
	UV88 = 22,
	UVWQ8888 = 23,
	RGBA16161616F = 24,
	RGBA16161616 = 25,
	UVLX8888 = 26,
	R32F = 27,
	RGB323232F = 28,
	RGBA32323232F = 29,
	ATI2N = 37,
	ATI1N = 38,
}

-- Get bytes per pixel for uncompressed formats
local function get_bytes_per_pixel(format)
	if
		format == VTF_IMAGE_FORMAT.RGBA8888 or
		format == VTF_IMAGE_FORMAT.ABGR8888 or
		format == VTF_IMAGE_FORMAT.ARGB8888 or
		format == VTF_IMAGE_FORMAT.BGRA8888 or
		format == VTF_IMAGE_FORMAT.BGRX8888 or
		format == VTF_IMAGE_FORMAT.UVWQ8888 or
		format == VTF_IMAGE_FORMAT.UVLX8888 or
		format == VTF_IMAGE_FORMAT.R32F
	then
		return 4
	elseif
		format == VTF_IMAGE_FORMAT.RGB888 or
		format == VTF_IMAGE_FORMAT.BGR888 or
		format == VTF_IMAGE_FORMAT.RGB888_BLUESCREEN or
		format == VTF_IMAGE_FORMAT.BGR888_BLUESCREEN
	then
		return 3
	elseif
		format == VTF_IMAGE_FORMAT.RGB565 or
		format == VTF_IMAGE_FORMAT.BGR565 or
		format == VTF_IMAGE_FORMAT.BGRX5551 or
		format == VTF_IMAGE_FORMAT.BGRA4444 or
		format == VTF_IMAGE_FORMAT.BGRA5551 or
		format == VTF_IMAGE_FORMAT.IA88 or
		format == VTF_IMAGE_FORMAT.UV88
	then
		return 2
	elseif
		format == VTF_IMAGE_FORMAT.I8 or
		format == VTF_IMAGE_FORMAT.P8 or
		format == VTF_IMAGE_FORMAT.A8
	then
		return 1
	elseif
		format == VTF_IMAGE_FORMAT.RGBA16161616F or
		format == VTF_IMAGE_FORMAT.RGBA16161616
	then
		return 8
	elseif format == VTF_IMAGE_FORMAT.RGB323232F then
		return 12
	elseif format == VTF_IMAGE_FORMAT.RGBA32323232F then
		return 16
	end

	return nil
end

-- Check if format is DXT compressed
local function is_compressed(format)
	return format == VTF_IMAGE_FORMAT.DXT1 or
		format == VTF_IMAGE_FORMAT.DXT3 or
		format == VTF_IMAGE_FORMAT.DXT5 or
		format == VTF_IMAGE_FORMAT.DXT1_ONEBITALPHA or
		format == VTF_IMAGE_FORMAT.ATI1N or
		format == VTF_IMAGE_FORMAT.ATI2N
end

-- Get block size for compressed formats
local function get_block_size(format)
	if
		format == VTF_IMAGE_FORMAT.DXT1 or
		format == VTF_IMAGE_FORMAT.DXT1_ONEBITALPHA or
		format == VTF_IMAGE_FORMAT.ATI1N
	then
		return 8
	elseif
		format == VTF_IMAGE_FORMAT.DXT3 or
		format == VTF_IMAGE_FORMAT.DXT5 or
		format == VTF_IMAGE_FORMAT.ATI2N
	then
		return 16
	end

	return nil
end

-- Calculate image data size
local function compute_image_size(width, height, depth, format)
	if is_compressed(format) then
		local block_size = get_block_size(format)
		local blocks_x = math.max(1, math.floor((width + 3) / 4))
		local blocks_y = math.max(1, math.floor((height + 3) / 4))
		return blocks_x * blocks_y * depth * block_size
	else
		local bpp = get_bytes_per_pixel(format)

		if bpp then return width * height * depth * bpp end
	end

	return nil
end

-- Map VTF format to Vulkan format name
local function vtf_to_vulkan_format(format)
	local format_map = {
		[VTF_IMAGE_FORMAT.DXT1] = "bc1_rgb_unorm_block",
		[VTF_IMAGE_FORMAT.DXT1_ONEBITALPHA] = "bc1_rgba_unorm_block",
		[VTF_IMAGE_FORMAT.DXT3] = "bc2_unorm_block",
		[VTF_IMAGE_FORMAT.DXT5] = "bc3_unorm_block",
		[VTF_IMAGE_FORMAT.ATI1N] = "bc4_unorm_block",
		[VTF_IMAGE_FORMAT.ATI2N] = "bc5_unorm_block",
		[VTF_IMAGE_FORMAT.RGBA8888] = "r8g8b8a8_unorm",
		[VTF_IMAGE_FORMAT.BGRA8888] = "b8g8r8a8_unorm",
		[VTF_IMAGE_FORMAT.ABGR8888] = "a8b8g8r8_unorm_pack32",
		[VTF_IMAGE_FORMAT.ARGB8888] = "b8g8r8a8_unorm", -- Close approximation
		-- 24-bit formats converted to 32-bit (not widely supported)
		[VTF_IMAGE_FORMAT.RGB888] = "r8g8b8a8_unorm",
		[VTF_IMAGE_FORMAT.BGR888] = "b8g8r8a8_unorm",
		[VTF_IMAGE_FORMAT.RGBA16161616F] = "r16g16b16a16_sfloat",
		[VTF_IMAGE_FORMAT.RGBA32323232F] = "r32g32b32a32_sfloat",
		[VTF_IMAGE_FORMAT.RGB323232F] = "r32g32b32_sfloat",
	}
	return format_map[format] or "undefined"
end

-- Parse VTF header
local function parse_header(buffer)
	local header = {}
	-- Read file header
	local signature = buffer:ReadBytes(4)

	if signature ~= "VTF\0" then
		return nil, "Not a VTF file (invalid signature)"
	end

	header.version_major = buffer:ReadU32LE()
	header.version_minor = buffer:ReadU32LE()
	header.header_size = buffer:ReadU32LE()
	-- Read image properties
	header.width = buffer:ReadU16LE()
	header.height = buffer:ReadU16LE()
	header.flags = buffer:ReadU32LE()
	header.frames = buffer:ReadU16LE()
	header.first_frame = buffer:ReadU16LE()
	-- Skip padding
	buffer:ReadBytes(4)
	-- Reflectivity
	header.reflectivity = {
		buffer:ReadFloat(),
		buffer:ReadFloat(),
		buffer:ReadFloat(),
	}
	-- Skip padding
	buffer:ReadBytes(4)
	header.bump_scale = buffer:ReadFloat()
	header.image_format = buffer:ReadU32LE()
	header.mip_count = buffer:ReadByte()
	header.lowres_image_format = buffer:ReadU32LE()
	header.lowres_width = buffer:ReadByte()
	header.lowres_height = buffer:ReadByte()

	-- Version 7.2+ has depth
	if header.version_minor >= 2 then
		header.depth = buffer:ReadU16LE()
	else
		header.depth = 1
	end

	-- Version 7.3+ has resources
	if header.version_minor >= 3 then
		buffer:ReadBytes(3) -- padding
		header.resource_count = buffer:ReadU32LE()
		buffer:ReadBytes(8) -- more padding
		-- Skip resources for now - we only need the main image
		if header.resource_count > 0 then
			buffer:ReadBytes(header.resource_count * 8) -- Skip resource entries
		end
	end

	return header
end

-- Main VTF decode function
local function vtf_decode(input_buffer)
	local header, err = parse_header(input_buffer)

	if not header then return nil, err end

	-- Position at start of image data using header_size
	-- This accounts for variable header sizes (v7.3+ has resources)
	input_buffer:SetPosition(header.header_size)

	-- The lowres image comes first (if present)
	if header.lowres_width > 0 and header.lowres_height > 0 then
		local lowres_size = compute_image_size(header.lowres_width, header.lowres_height, 1, header.lowres_image_format)

		if lowres_size then
			input_buffer:ReadBytes(lowres_size) -- Skip lowres image
		end
	end

	local width = header.width
	local height = header.height
	local depth = header.depth
	local format = header.image_format
	local mip_count = header.mip_count
	local frames = header.frames
	-- Calculate mipmap info and total data size
	-- VTF stores mipmaps from smallest to largest in the file
	-- First pass: calculate sizes for each mip level
	local mip_sizes = {}
	local total_size = 0

	for mip_level = 0, mip_count - 1 do
		local mip_width = math.max(1, math.floor(width / math.pow(2, mip_level)))
		local mip_height = math.max(1, math.floor(height / math.pow(2, mip_level)))
		local mip_depth = depth
		local mip_size = compute_image_size(mip_width, mip_height, mip_depth, format)

		if not mip_size then
			return nil, "Unsupported image format: " .. tostring(format)
		end

		mip_sizes[mip_level] = {
			width = mip_width,
			height = mip_height,
			depth = mip_depth,
			size = mip_size,
		}
		total_size = total_size + mip_size
	end

	-- Second pass: calculate offsets in file order (smallest to largest)
	-- and build mip_info in API order (largest first)
	-- VTF stores: for each mip level { for each frame { for each face { data } } }
	local mip_info = {}
	local file_offset = 0
	local face_count = 1 -- Most textures have 1 face, cubemaps have 6
	for file_mip_index = 0, mip_count - 1 do
		-- File stores smallest first, so file_mip_index 0 = mip level (mip_count-1)
		local mip_level = mip_count - 1 - file_mip_index
		local mip_data = mip_sizes[mip_level]
		-- Store in API order: index 1 = mip level 0 (largest)
		-- The offset points to frame 0, face 0 of this mip level
		mip_info[mip_level + 1] = {
			width = mip_data.width,
			height = mip_data.height,
			depth = mip_data.depth,
			size = mip_data.size,
			offset = file_offset,
		}
		-- Each mip level contains data for ALL frames and faces
		file_offset = file_offset + (mip_data.size * frames * face_count)
	end

	-- For multiple frames, we only read the first frame
	-- Calculate how much data to skip for other frames
	local frame_data_size = total_size
	-- Read all mipmap data for the first frame
	local data_pos = input_buffer:GetPosition()
	-- Check if we need to convert 24-bit to 32-bit
	local bpp = get_bytes_per_pixel(format)
	local needs_conversion_to_32bit = (bpp == 3) -- 24-bit RGB/BGR
	local data_buffer
	local actual_data_size = total_size

	if needs_conversion_to_32bit then
		-- Convert 24-bit to 32-bit by adding alpha/X channel
		local pixel_count = 0

		for _, mip_data in ipairs(mip_sizes) do
			pixel_count = pixel_count + (mip_data.width * mip_data.height * mip_data.depth)
		end

		local new_size = pixel_count * 4 -- 4 bytes per pixel
		data_buffer = ffi.new("uint8_t[?]", new_size)
		local src = input_buffer:GetBuffer() + data_pos
		local dst = data_buffer
		local src_idx = 0
		local dst_idx = 0

		-- Copy RGB and add 255 for X channel (unused alpha)
		for i = 0, pixel_count - 1 do
			dst[dst_idx] = src[src_idx] -- R or B
			dst[dst_idx + 1] = src[src_idx + 1] -- G
			dst[dst_idx + 2] = src[src_idx + 2] -- B or R
			dst[dst_idx + 3] = 255 -- X (unused, fully opaque)
			src_idx = src_idx + 3
			dst_idx = dst_idx + 4
		end

		actual_data_size = new_size

		-- Update mip_info sizes to reflect 32-bit
		for i, mip in ipairs(mip_info) do
			mip.size = (mip.width * mip.height * mip.depth) * 4

			if i > 1 then mip.offset = mip_info[i - 1].offset + mip_info[i - 1].size end
		end
	else
		data_buffer = ffi.new("uint8_t[?]", total_size)
		ffi.copy(data_buffer, input_buffer:GetBuffer() + data_pos, total_size)
	end

	-- Get Vulkan format string
	local vulkan_format = vtf_to_vulkan_format(format)
	-- Return result matching DDS decoder pattern
	return {
		width = width,
		height = height,
		depth = depth,
		format = format,
		vtf_format = format, -- Keep VTF-specific format enum
		vulkan_format = vulkan_format,
		mip_count = mip_count,
		frames = frames,
		is_compressed = is_compressed(format),
		block_size = get_block_size(format),
		bytes_per_pixel = needs_conversion_to_32bit and 4 or get_bytes_per_pixel(format),
		mip_info = mip_info,
		data_size = actual_data_size,
		data = data_buffer,
		-- Also provide a Buffer wrapper for consistency
		buffer = Buffer.New(data_buffer, actual_data_size),
	}
end

local vtf = {}
vtf.DecodeBuffer = vtf_decode
vtf.file_extensions = {"vtf"}
return vtf
