-- DDS (DirectDraw Surface) decoder for LuaJIT
-- Supports DXT1/BC1, DXT3/BC2, DXT5/BC3, BC4, BC5, BC6H, BC7, and uncompressed formats
-- Returns compressed data as-is for GPU upload (no decompression to RGBA)
local ffi = require("ffi")
local bit = require("bit")
local Buffer = require("structs.buffer")
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
-- DDS magic number
local DDS_MAGIC = 0x20534444 -- "DDS "
-- DDS header flags
local DDSD_CAPS = 0x00000001
local DDSD_HEIGHT = 0x00000002
local DDSD_WIDTH = 0x00000004
local DDSD_PITCH = 0x00000008
local DDSD_PIXELFORMAT = 0x00001000
local DDSD_MIPMAPCOUNT = 0x00020000
local DDSD_LINEARSIZE = 0x00080000
local DDSD_DEPTH = 0x00800000
-- DDS pixel format flags
local DDPF_ALPHAPIXELS = 0x00000001
local DDPF_ALPHA = 0x00000002
local DDPF_FOURCC = 0x00000004
local DDPF_RGB = 0x00000040
local DDPF_YUV = 0x00000200
local DDPF_LUMINANCE = 0x00020000
-- DDS caps flags
local DDSCAPS_COMPLEX = 0x00000008
local DDSCAPS_MIPMAP = 0x00400000
local DDSCAPS_TEXTURE = 0x00001000
-- DDS caps2 flags
local DDSCAPS2_CUBEMAP = 0x00000200
local DDSCAPS2_CUBEMAP_POSITIVEX = 0x00000400
local DDSCAPS2_CUBEMAP_NEGATIVEX = 0x00000800
local DDSCAPS2_CUBEMAP_POSITIVEY = 0x00001000
local DDSCAPS2_CUBEMAP_NEGATIVEY = 0x00002000
local DDSCAPS2_CUBEMAP_POSITIVEZ = 0x00004000
local DDSCAPS2_CUBEMAP_NEGATIVEZ = 0x00008000
local DDSCAPS2_VOLUME = 0x00200000
-- FourCC codes
local FOURCC_DXT1 = 0x31545844 -- "DXT1"
local FOURCC_DXT2 = 0x32545844 -- "DXT2"
local FOURCC_DXT3 = 0x33545844 -- "DXT3"
local FOURCC_DXT4 = 0x34545844 -- "DXT4"
local FOURCC_DXT5 = 0x35545844 -- "DXT5"
local FOURCC_DX10 = 0x30315844 -- "DX10"
local FOURCC_ATI1 = 0x31495441 -- "ATI1" (BC4)
local FOURCC_ATI2 = 0x32495441 -- "ATI2" (BC5)
local FOURCC_BC4U = 0x55344342 -- "BC4U"
local FOURCC_BC4S = 0x53344342 -- "BC4S"
local FOURCC_BC5U = 0x55354342 -- "BC5U"
local FOURCC_BC5S = 0x53354342 -- "BC5S"
-- DXGI format enum (subset for common formats)
local DXGI_FORMAT = {
	UNKNOWN = 0,
	R32G32B32A32_TYPELESS = 1,
	R32G32B32A32_FLOAT = 2,
	R32G32B32A32_UINT = 3,
	R32G32B32A32_SINT = 4,
	R32G32B32_TYPELESS = 5,
	R32G32B32_FLOAT = 6,
	R32G32B32_UINT = 7,
	R32G32B32_SINT = 8,
	R16G16B16A16_TYPELESS = 9,
	R16G16B16A16_FLOAT = 10,
	R16G16B16A16_UNORM = 11,
	R16G16B16A16_UINT = 12,
	R16G16B16A16_SNORM = 13,
	R16G16B16A16_SINT = 14,
	R32G32_TYPELESS = 15,
	R32G32_FLOAT = 16,
	R32G32_UINT = 17,
	R32G32_SINT = 18,
	R8G8B8A8_TYPELESS = 27,
	R8G8B8A8_UNORM = 28,
	R8G8B8A8_UNORM_SRGB = 29,
	R8G8B8A8_UINT = 30,
	R8G8B8A8_SNORM = 31,
	R8G8B8A8_SINT = 32,
	B8G8R8A8_UNORM = 87,
	B8G8R8A8_UNORM_SRGB = 91,
	B8G8R8X8_UNORM = 88,
	B8G8R8X8_UNORM_SRGB = 93,
	BC1_TYPELESS = 70,
	BC1_UNORM = 71,
	BC1_UNORM_SRGB = 72,
	BC2_TYPELESS = 73,
	BC2_UNORM = 74,
	BC2_UNORM_SRGB = 75,
	BC3_TYPELESS = 76,
	BC3_UNORM = 77,
	BC3_UNORM_SRGB = 78,
	BC4_TYPELESS = 79,
	BC4_UNORM = 80,
	BC4_SNORM = 81,
	BC5_TYPELESS = 82,
	BC5_UNORM = 83,
	BC5_SNORM = 84,
	BC6H_TYPELESS = 94,
	BC6H_UF16 = 95,
	BC6H_SF16 = 96,
	BC7_TYPELESS = 97,
	BC7_UNORM = 98,
	BC7_UNORM_SRGB = 99,
}
-- Reverse lookup for DXGI format names
local DXGI_FORMAT_NAMES = {}

for name, value in pairs(DXGI_FORMAT) do
	DXGI_FORMAT_NAMES[value] = name
end

-- D3D10/11 resource dimension
local D3D10_RESOURCE_DIMENSION = {
	UNKNOWN = 0,
	BUFFER = 1,
	TEXTURE1D = 2,
	TEXTURE2D = 3,
	TEXTURE3D = 4,
}
-- D3D10/11 resource misc flags
local D3D10_RESOURCE_MISC_TEXTURECUBE = 0x4

-- Helper to read a FourCC as a string for debugging
local function fourcc_to_string(fourcc)
	return string.char(
		band(fourcc, 0xFF),
		band(rshift(fourcc, 8), 0xFF),
		band(rshift(fourcc, 16), 0xFF),
		band(rshift(fourcc, 24), 0xFF)
	)
end

-- Helper to make a FourCC from string
local function string_to_fourcc(str)
	return bor(
		str:byte(1),
		lshift(str:byte(2), 8),
		lshift(str:byte(3), 16),
		lshift(str:byte(4), 24)
	)
end

-- Get block size for compressed formats (4x4 block)
local function get_block_size(format)
	if
		format == "BC1" or
		format == "BC1_SRGB" or
		format == "BC4" or
		format == "BC4_SNORM"
	then
		return 8 -- 8 bytes per 4x4 block
	elseif
		format == "BC2" or
		format == "BC2_SRGB" or
		format == "BC3" or
		format == "BC3_SRGB" or
		format == "BC5" or
		format == "BC5_SNORM" or
		format == "BC6H_UF16" or
		format == "BC6H_SF16" or
		format == "BC7" or
		format == "BC7_SRGB"
	then
		return 16 -- 16 bytes per 4x4 block
	end

	return nil -- Not a block compressed format
end

-- Check if format is compressed
local function is_compressed(format)
	return get_block_size(format) ~= nil
end

-- Get bytes per pixel for uncompressed formats
local function get_bytes_per_pixel(format)
	local bpp_map = {
		R8G8B8A8_UNORM = 4,
		R8G8B8A8_UNORM_SRGB = 4,
		B8G8R8A8_UNORM = 4,
		B8G8R8A8_UNORM_SRGB = 4,
		B8G8R8X8_UNORM = 4,
		B8G8R8X8_UNORM_SRGB = 4,
		R16G16B16A16_FLOAT = 8,
		R16G16B16A16_UNORM = 8,
		R32G32B32A32_FLOAT = 16,
		R32G32B32_FLOAT = 12,
		R32G32_FLOAT = 8,
		R8_UNORM = 1,
		R8G8_UNORM = 2,
		A8_UNORM = 1,
		R16_FLOAT = 2,
		R32_FLOAT = 4,
	}
	return bpp_map[format]
end

-- Calculate data size for a mip level
local function calculate_mip_size(width, height, depth, format)
	local block_size = get_block_size(format)

	if block_size then
		-- Block compressed format
		local blocks_x = math.max(1, math.floor((width + 3) / 4))
		local blocks_y = math.max(1, math.floor((height + 3) / 4))
		return blocks_x * blocks_y * depth * block_size
	else
		-- Uncompressed format
		local bpp = get_bytes_per_pixel(format)

		if bpp then return width * height * depth * bpp end
	end

	return nil
end

-- Map DXGI format to Vulkan format name
local function dxgi_to_vulkan_format(dxgi_format)
	local format_map = {
		[DXGI_FORMAT.BC1_UNORM] = "bc1_rgba_unorm_block",
		[DXGI_FORMAT.BC1_UNORM_SRGB] = "bc1_rgba_srgb_block",
		[DXGI_FORMAT.BC2_UNORM] = "bc2_unorm_block",
		[DXGI_FORMAT.BC2_UNORM_SRGB] = "bc2_srgb_block",
		[DXGI_FORMAT.BC3_UNORM] = "bc3_unorm_block",
		[DXGI_FORMAT.BC3_UNORM_SRGB] = "bc3_srgb_block",
		[DXGI_FORMAT.BC4_UNORM] = "bc4_unorm_block",
		[DXGI_FORMAT.BC4_SNORM] = "bc4_snorm_block",
		[DXGI_FORMAT.BC5_UNORM] = "bc5_unorm_block",
		[DXGI_FORMAT.BC5_SNORM] = "bc5_snorm_block",
		[DXGI_FORMAT.BC6H_UF16] = "bc6h_ufloat_block",
		[DXGI_FORMAT.BC6H_SF16] = "bc6h_sfloat_block",
		[DXGI_FORMAT.BC7_UNORM] = "bc7_unorm_block",
		[DXGI_FORMAT.BC7_UNORM_SRGB] = "bc7_srgb_block",
		[DXGI_FORMAT.R8G8B8A8_UNORM] = "r8g8b8a8_unorm",
		[DXGI_FORMAT.R8G8B8A8_UNORM_SRGB] = "r8g8b8a8_srgb",
		[DXGI_FORMAT.B8G8R8A8_UNORM] = "b8g8r8a8_unorm",
		[DXGI_FORMAT.B8G8R8A8_UNORM_SRGB] = "b8g8r8a8_srgb",
		[DXGI_FORMAT.R16G16B16A16_FLOAT] = "r16g16b16a16_sfloat",
		[DXGI_FORMAT.R32G32B32A32_FLOAT] = "r32g32b32a32_sfloat",
		[DXGI_FORMAT.R32G32B32_FLOAT] = "r32g32b32_sfloat",
	}
	return format_map[dxgi_format]
end

-- Map internal format string to Vulkan format name
local function format_to_vulkan(format)
	local format_map = {
		BC1 = "bc1_rgba_unorm_block",
		BC1_SRGB = "bc1_rgba_srgb_block",
		BC2 = "bc2_unorm_block",
		BC2_SRGB = "bc2_srgb_block",
		BC3 = "bc3_unorm_block",
		BC3_SRGB = "bc3_srgb_block",
		BC4 = "bc4_unorm_block",
		BC4_SNORM = "bc4_snorm_block",
		BC5 = "bc5_unorm_block",
		BC5_SNORM = "bc5_snorm_block",
		BC6H_UF16 = "bc6h_ufloat_block",
		BC6H_SF16 = "bc6h_sfloat_block",
		BC7 = "bc7_unorm_block",
		BC7_SRGB = "bc7_srgb_block",
		R8G8B8A8_UNORM = "r8g8b8a8_unorm",
		R8G8B8A8_UNORM_SRGB = "r8g8b8a8_srgb",
		B8G8R8A8_UNORM = "b8g8r8a8_unorm",
		B8G8R8A8_UNORM_SRGB = "b8g8r8a8_srgb",
		B8G8R8X8_UNORM = "b8g8r8a8_unorm", -- Treat X as A
		B8G8R8X8_UNORM_SRGB = "b8g8r8a8_srgb",
		R16G16B16A16_FLOAT = "r16g16b16a16_sfloat",
		R32G32B32A32_FLOAT = "r32g32b32a32_sfloat",
		R32G32B32_FLOAT = "r32g32b32_sfloat",
	}
	return format_map[format] or format
end

-- Parse pixel format from DDS header
local function parse_pixel_format(buffer)
	local pf = {}
	pf.size = buffer:ReadU32LE()
	pf.flags = buffer:ReadU32LE()
	pf.fourCC = buffer:ReadU32LE()
	pf.rgbBitCount = buffer:ReadU32LE()
	pf.rBitMask = buffer:ReadU32LE()
	pf.gBitMask = buffer:ReadU32LE()
	pf.bBitMask = buffer:ReadU32LE()
	pf.aBitMask = buffer:ReadU32LE()
	return pf
end

-- Parse DX10 extended header
local function parse_dx10_header(buffer)
	local dx10 = {}
	dx10.dxgiFormat = buffer:ReadU32LE()
	dx10.resourceDimension = buffer:ReadU32LE()
	dx10.miscFlag = buffer:ReadU32LE()
	dx10.arraySize = buffer:ReadU32LE()
	dx10.miscFlags2 = buffer:ReadU32LE()
	return dx10
end

-- Determine format from pixel format structure
-- Returns an internal format name suitable for size calculations
local function determine_format(pf, dx10)
	-- Check for DX10 extended header first
	if dx10 then
		-- Map DXGI format to internal format name
		local dxgi_to_internal = {
			[DXGI_FORMAT.BC1_UNORM] = "BC1",
			[DXGI_FORMAT.BC1_UNORM_SRGB] = "BC1_SRGB",
			[DXGI_FORMAT.BC2_UNORM] = "BC2",
			[DXGI_FORMAT.BC2_UNORM_SRGB] = "BC2_SRGB",
			[DXGI_FORMAT.BC3_UNORM] = "BC3",
			[DXGI_FORMAT.BC3_UNORM_SRGB] = "BC3_SRGB",
			[DXGI_FORMAT.BC4_UNORM] = "BC4",
			[DXGI_FORMAT.BC4_SNORM] = "BC4_SNORM",
			[DXGI_FORMAT.BC5_UNORM] = "BC5",
			[DXGI_FORMAT.BC5_SNORM] = "BC5_SNORM",
			[DXGI_FORMAT.BC6H_UF16] = "BC6H_UF16",
			[DXGI_FORMAT.BC6H_SF16] = "BC6H_SF16",
			[DXGI_FORMAT.BC7_UNORM] = "BC7",
			[DXGI_FORMAT.BC7_UNORM_SRGB] = "BC7_SRGB",
			[DXGI_FORMAT.R8G8B8A8_UNORM] = "r8g8b8a8_unorm",
			[DXGI_FORMAT.R8G8B8A8_UNORM_SRGB] = "R8G8B8A8_UNORM_SRGB",
			[DXGI_FORMAT.B8G8R8A8_UNORM] = "B8G8R8A8_UNORM",
			[DXGI_FORMAT.B8G8R8A8_UNORM_SRGB] = "B8G8R8A8_UNORM_SRGB",
			[DXGI_FORMAT.B8G8R8X8_UNORM] = "B8G8R8X8_UNORM",
			[DXGI_FORMAT.B8G8R8X8_UNORM_SRGB] = "B8G8R8X8_UNORM_SRGB",
			[DXGI_FORMAT.R16G16B16A16_FLOAT] = "R16G16B16A16_FLOAT",
			[DXGI_FORMAT.R32G32B32A32_FLOAT] = "R32G32B32A32_FLOAT",
			[DXGI_FORMAT.R32G32B32_FLOAT] = "R32G32B32_FLOAT",
		}
		local internal = dxgi_to_internal[dx10.dxgiFormat]

		if internal then return internal end

		-- Return DXGI format name if we don't have a mapping
		local name = DXGI_FORMAT_NAMES[dx10.dxgiFormat]

		if name then return name end

		return "DXGI_" .. dx10.dxgiFormat
	end

	-- Check for FourCC formats
	if band(pf.flags, DDPF_FOURCC) ~= 0 then
		if pf.fourCC == FOURCC_DXT1 then
			return "BC1"
		elseif pf.fourCC == FOURCC_DXT2 or pf.fourCC == FOURCC_DXT3 then
			return "BC2"
		elseif pf.fourCC == FOURCC_DXT4 or pf.fourCC == FOURCC_DXT5 then
			return "BC3"
		elseif pf.fourCC == FOURCC_ATI1 or pf.fourCC == FOURCC_BC4U then
			return "BC4"
		elseif pf.fourCC == FOURCC_BC4S then
			return "BC4_SNORM"
		elseif pf.fourCC == FOURCC_ATI2 or pf.fourCC == FOURCC_BC5U then
			return "BC5"
		elseif pf.fourCC == FOURCC_BC5S then
			return "BC5_SNORM"
		else
			-- Unknown FourCC
			return "FOURCC_" .. fourcc_to_string(pf.fourCC)
		end
	end

	-- Check for uncompressed RGB formats
	if band(pf.flags, DDPF_RGB) ~= 0 then
		local has_alpha = band(pf.flags, DDPF_ALPHAPIXELS) ~= 0

		if pf.rgbBitCount == 32 then
			-- Check bit masks to determine format
			if
				pf.rBitMask == 0x00FF0000 and
				pf.gBitMask == 0x0000FF00 and
				pf.bBitMask == 0x000000FF
			then
				if has_alpha and pf.aBitMask == 0xFF000000 then
					return "B8G8R8A8_UNORM"
				else
					return "B8G8R8X8_UNORM"
				end
			elseif
				pf.rBitMask == 0x000000FF and
				pf.gBitMask == 0x0000FF00 and
				pf.bBitMask == 0x00FF0000
			then
				if has_alpha and pf.aBitMask == 0xFF000000 then
					return "r8g8b8a8_unorm"
				else
					return "R8G8B8X8_UNORM"
				end
			end
		elseif pf.rgbBitCount == 24 then
			-- 24-bit formats are not widely supported in Vulkan
			-- Convert to 32-bit equivalents by adding X (unused alpha) channel
			if
				pf.rBitMask == 0x00FF0000 and
				pf.gBitMask == 0x0000FF00 and
				pf.bBitMask == 0x000000FF
			then
				return "B8G8R8X8_UNORM" -- Was B8G8R8_UNORM, but that's unsupported
			elseif
				pf.rBitMask == 0x000000FF and
				pf.gBitMask == 0x0000FF00 and
				pf.bBitMask == 0x00FF0000
			then
				return "R8G8B8X8_UNORM" -- Was R8G8B8_UNORM, but that's unsupported
			end
		end
	end

	-- Check for luminance formats
	if band(pf.flags, DDPF_LUMINANCE) ~= 0 then
		local has_alpha = band(pf.flags, DDPF_ALPHAPIXELS) ~= 0

		if pf.rgbBitCount == 8 then
			return has_alpha and "R8G8_UNORM" or "R8_UNORM"
		elseif pf.rgbBitCount == 16 then
			return has_alpha and "R8G8_UNORM" or "R16_UNORM"
		end
	end

	-- Check for alpha-only formats
	if band(pf.flags, DDPF_ALPHA) ~= 0 then
		if pf.rgbBitCount == 8 then return "A8_UNORM" end
	end

	return "UNKNOWN"
end

-- Main decode function
local function decode(inputBuffer, opts)
	opts = opts or {}
	-- Read and validate magic number
	local magic = inputBuffer:ReadU32LE()

	if magic ~= DDS_MAGIC then
		error("Not a valid DDS file (invalid magic number)")
	end

	-- Read DDS header (124 bytes)
	local header = {}
	header.size = inputBuffer:ReadU32LE()

	if header.size ~= 124 then
		error("Invalid DDS header size: " .. header.size)
	end

	header.flags = inputBuffer:ReadU32LE()
	header.height = inputBuffer:ReadU32LE()
	header.width = inputBuffer:ReadU32LE()
	header.pitchOrLinearSize = inputBuffer:ReadU32LE()
	header.depth = inputBuffer:ReadU32LE()
	header.mipMapCount = inputBuffer:ReadU32LE()

	-- Reserved1[11]
	for i = 1, 11 do
		inputBuffer:ReadU32LE()
	end

	-- Pixel format
	header.pixelFormat = parse_pixel_format(inputBuffer)
	-- Caps
	header.caps = inputBuffer:ReadU32LE()
	header.caps2 = inputBuffer:ReadU32LE()
	header.caps3 = inputBuffer:ReadU32LE()
	header.caps4 = inputBuffer:ReadU32LE()
	inputBuffer:ReadU32LE() -- reserved2
	-- Check for DX10 extended header
	local dx10 = nil

	if
		band(header.pixelFormat.flags, DDPF_FOURCC) ~= 0 and
		header.pixelFormat.fourCC == FOURCC_DX10
	then
		dx10 = parse_dx10_header(inputBuffer)
	end

	-- Determine format
	local format = determine_format(header.pixelFormat, dx10)
	local vulkan_format = format_to_vulkan(format)
	-- Determine texture type and array/cube info
	local is_cubemap = band(header.caps2, DDSCAPS2_CUBEMAP) ~= 0
	local is_volume = band(header.caps2, DDSCAPS2_VOLUME) ~= 0
	local array_size = 1

	if dx10 then
		array_size = dx10.arraySize

		if band(dx10.miscFlag, D3D10_RESOURCE_MISC_TEXTURECUBE) ~= 0 then
			is_cubemap = true
			array_size = array_size * 6
		end
	elseif is_cubemap then
		-- Count cubemap faces
		array_size = 0

		if band(header.caps2, DDSCAPS2_CUBEMAP_POSITIVEX) ~= 0 then
			array_size = array_size + 1
		end

		if band(header.caps2, DDSCAPS2_CUBEMAP_NEGATIVEX) ~= 0 then
			array_size = array_size + 1
		end

		if band(header.caps2, DDSCAPS2_CUBEMAP_POSITIVEY) ~= 0 then
			array_size = array_size + 1
		end

		if band(header.caps2, DDSCAPS2_CUBEMAP_NEGATIVEY) ~= 0 then
			array_size = array_size + 1
		end

		if band(header.caps2, DDSCAPS2_CUBEMAP_POSITIVEZ) ~= 0 then
			array_size = array_size + 1
		end

		if band(header.caps2, DDSCAPS2_CUBEMAP_NEGATIVEZ) ~= 0 then
			array_size = array_size + 1
		end
	end

	-- Mipmap count
	local mip_count = header.mipMapCount

	if mip_count == 0 then mip_count = 1 end

	-- Depth for volume textures
	local depth = 1

	if is_volume and header.depth > 0 then depth = header.depth end

	-- Calculate total data size
	local total_size = 0
	local mip_info = {}

	for face = 1, array_size do
		local mip_width = header.width
		local mip_height = header.height
		local mip_depth = depth

		for mip = 1, mip_count do
			local mip_size = calculate_mip_size(mip_width, mip_height, mip_depth, format)

			if not mip_size then
				error("Cannot calculate size for format: " .. format)
			end

			if face == 1 then
				mip_info[mip] = {
					width = mip_width,
					height = mip_height,
					depth = mip_depth,
					size = mip_size,
					offset = total_size,
				}
			end

			total_size = total_size + mip_size
			mip_width = math.max(1, math.floor(mip_width / 2))
			mip_height = math.max(1, math.floor(mip_height / 2))

			if is_volume then mip_depth = math.max(1, math.floor(mip_depth / 2)) end
		end
	end

	-- Read all image data
	local data_pos = inputBuffer:GetPosition()
	local remaining = inputBuffer:GetSize() - data_pos

	if remaining < total_size then
		-- Some files may have less data than expected (truncated mipmaps)
		total_size = remaining
	end

	-- Get pointer to the data directly (no copy for efficiency)
	local data_buffer
	local actual_data_size = total_size
	-- Check if we need to convert 24-bit to 32-bit
	local bpp = get_bytes_per_pixel(format)
	local needs_conversion_to_32bit = (bpp == 3) -- 24-bit RGB/BGR
	if needs_conversion_to_32bit then
		-- Convert 24-bit to 32-bit by adding alpha channel
		local pixel_count = header.width * header.height * depth * array_size
		local new_size = pixel_count * 4 -- 4 bytes per pixel
		data_buffer = ffi.new("uint8_t[?]", new_size)
		local src = inputBuffer:GetBuffer() + data_pos
		local dst = data_buffer
		local src_idx = 0
		local dst_idx = 0

		-- Copy RGB and add 255 alpha
		for i = 0, pixel_count - 1 do
			dst[dst_idx] = src[src_idx] -- R or B
			dst[dst_idx + 1] = src[src_idx + 1] -- G
			dst[dst_idx + 2] = src[src_idx + 2] -- B or R
			dst[dst_idx + 3] = 255 -- A (fully opaque)
			src_idx = src_idx + 3
			dst_idx = dst_idx + 4
		end

		actual_data_size = new_size
	else
		data_buffer = ffi.new("uint8_t[?]", total_size)
		ffi.copy(data_buffer, inputBuffer:GetBuffer() + data_pos, total_size)
	end

	-- Return result with all the metadata needed for GPU upload
	return {
		width = header.width,
		height = header.height,
		depth = depth,
		format = format,
		vulkan_format = vulkan_format,
		mip_count = mip_count,
		array_size = array_size,
		is_cubemap = is_cubemap,
		is_volume = is_volume,
		is_compressed = is_compressed(format),
		block_size = get_block_size(format),
		bytes_per_pixel = needs_conversion_to_32bit and 4 or get_bytes_per_pixel(format),
		mip_info = mip_info,
		data_size = actual_data_size,
		data = data_buffer,
		-- Also provide a Buffer wrapper for consistency with other decoders
		buffer = Buffer.New(data_buffer, actual_data_size),
	}
end

return decode
