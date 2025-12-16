-- VTF (Valve Texture Format) decoder for LuaJIT
-- Decodes VTF textures to RGBA8888 format
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

-- DXT1 decompression
local function decompress_dxt1(input_buffer, width, height)
	local output_size = width * height * 4
	local output = ffi.new("uint8_t[?]", output_size)
	local blocks_x = math.max(1, math.floor((width + 3) / 4))
	local blocks_y = math.max(1, math.floor((height + 3) / 4))

	for by = 0, blocks_y - 1 do
		for bx = 0, blocks_x - 1 do
			-- Read color endpoints
			local c0 = input_buffer:ReadU16LE()
			local c1 = input_buffer:ReadU16LE()
			local indices = input_buffer:ReadU32LE()
			-- Decode RGB565 colors
			local r0 = band(rshift(c0, 11), 0x1F)
			local g0 = band(rshift(c0, 5), 0x3F)
			local b0 = band(c0, 0x1F)
			local r1 = band(rshift(c1, 11), 0x1F)
			local g1 = band(rshift(c1, 5), 0x3F)
			local b1 = band(c1, 0x1F)
			-- Expand to 8-bit
			r0 = bor(lshift(r0, 3), rshift(r0, 2))
			g0 = bor(lshift(g0, 2), rshift(g0, 4))
			b0 = bor(lshift(b0, 3), rshift(b0, 2))
			r1 = bor(lshift(r1, 3), rshift(r1, 2))
			g1 = bor(lshift(g1, 2), rshift(g1, 4))
			b1 = bor(lshift(b1, 3), rshift(b1, 2))

			-- Decode 4x4 block
			for py = 0, 3 do
				for px = 0, 3 do
					local x = bx * 4 + px
					local y = by * 4 + py

					if x < width and y < height then
						local index = band(rshift(indices, (py * 4 + px) * 2), 0x3)
						local r, g, b, a

						if c0 > c1 then
							-- Four-color block
							if index == 0 then
								r, g, b = r0, g0, b0
							elseif index == 1 then
								r, g, b = r1, g1, b1
							elseif index == 2 then
								r = math.floor((2 * r0 + r1) / 3)
								g = math.floor((2 * g0 + g1) / 3)
								b = math.floor((2 * b0 + b1) / 3)
							else
								r = math.floor((r0 + 2 * r1) / 3)
								g = math.floor((g0 + 2 * g1) / 3)
								b = math.floor((b0 + 2 * b1) / 3)
							end

							a = 255
						else
							-- Three-color block with transparency
							if index == 0 then
								r, g, b = r0, g0, b0
							elseif index == 1 then
								r, g, b = r1, g1, b1
							elseif index == 2 then
								r = math.floor((r0 + r1) / 2)
								g = math.floor((g0 + g1) / 2)
								b = math.floor((b0 + b1) / 2)
							else
								r, g, b = 0, 0, 0
							end

							a = (index == 3) and 0 or 255
						end

						local offset = (y * width + x) * 4
						output[offset + 0] = r
						output[offset + 1] = g
						output[offset + 2] = b
						output[offset + 3] = a
					end
				end
			end
		end
	end

	return Buffer.New(output, output_size)
end

-- DXT3 decompression
local function decompress_dxt3(input_buffer, width, height)
	local output_size = width * height * 4
	local output = ffi.new("uint8_t[?]", output_size)
	local blocks_x = math.max(1, math.floor((width + 3) / 4))
	local blocks_y = math.max(1, math.floor((height + 3) / 4))

	for by = 0, blocks_y - 1 do
		for bx = 0, blocks_x - 1 do
			-- Read alpha data (8 bytes)
			local alpha_data = {}

			for i = 0, 7 do
				alpha_data[i] = input_buffer:ReadByte()
			end

			-- Read color data
			local c0 = input_buffer:ReadU16LE()
			local c1 = input_buffer:ReadU16LE()
			local indices = input_buffer:ReadU32LE()
			-- Decode RGB565 colors
			local r0 = band(rshift(c0, 11), 0x1F)
			local g0 = band(rshift(c0, 5), 0x3F)
			local b0 = band(c0, 0x1F)
			local r1 = band(rshift(c1, 11), 0x1F)
			local g1 = band(rshift(c1, 5), 0x3F)
			local b1 = band(c1, 0x1F)
			r0 = bor(lshift(r0, 3), rshift(r0, 2))
			g0 = bor(lshift(g0, 2), rshift(g0, 4))
			b0 = bor(lshift(b0, 3), rshift(b0, 2))
			r1 = bor(lshift(r1, 3), rshift(r1, 2))
			g1 = bor(lshift(g1, 2), rshift(g1, 4))
			b1 = bor(lshift(b1, 3), rshift(b1, 2))

			-- Decode 4x4 block
			for py = 0, 3 do
				for px = 0, 3 do
					local x = bx * 4 + px
					local y = by * 4 + py

					if x < width and y < height then
						-- Get color index
						local index = band(rshift(indices, (py * 4 + px) * 2), 0x3)
						local r, g, b

						if index == 0 then
							r, g, b = r0, g0, b0
						elseif index == 1 then
							r, g, b = r1, g1, b1
						elseif index == 2 then
							r = math.floor((2 * r0 + r1) / 3)
							g = math.floor((2 * g0 + g1) / 3)
							b = math.floor((2 * b0 + b1) / 3)
						else
							r = math.floor((r0 + 2 * r1) / 3)
							g = math.floor((g0 + 2 * g1) / 3)
							b = math.floor((b0 + 2 * b1) / 3)
						end

						-- Get alpha (4 bits per pixel)
						local alpha_byte_idx = math.floor((py * 4 + px) / 2)
						local alpha_nibble = band(rshift(alpha_data[alpha_byte_idx], ((py * 4 + px) % 2) * 4), 0xF)
						local a = bor(lshift(alpha_nibble, 4), alpha_nibble) -- Expand 4-bit to 8-bit
						local offset = (y * width + x) * 4
						output[offset + 0] = r
						output[offset + 1] = g
						output[offset + 2] = b
						output[offset + 3] = a
					end
				end
			end
		end
	end

	return Buffer.New(output, output_size)
end

-- DXT5 decompression
local function decompress_dxt5(input_buffer, width, height)
	local output_size = width * height * 4
	local output = ffi.new("uint8_t[?]", output_size)
	local blocks_x = math.max(1, math.floor((width + 3) / 4))
	local blocks_y = math.max(1, math.floor((height + 3) / 4))

	for by = 0, blocks_y - 1 do
		for bx = 0, blocks_x - 1 do
			-- Read alpha endpoints
			local a0 = input_buffer:ReadByte()
			local a1 = input_buffer:ReadByte()
			-- Read alpha indices (6 bytes = 48 bits for 16 pixels, 3 bits each)
			local alpha_indices = {}

			for i = 0, 5 do
				alpha_indices[i] = input_buffer:ReadByte()
			end

			-- Read color data
			local c0 = input_buffer:ReadU16LE()
			local c1 = input_buffer:ReadU16LE()
			local indices = input_buffer:ReadU32LE()
			-- Decode RGB565 colors
			local r0 = band(rshift(c0, 11), 0x1F)
			local g0 = band(rshift(c0, 5), 0x3F)
			local b0 = band(c0, 0x1F)
			local r1 = band(rshift(c1, 11), 0x1F)
			local g1 = band(rshift(c1, 5), 0x3F)
			local b1 = band(c1, 0x1F)
			r0 = bor(lshift(r0, 3), rshift(r0, 2))
			g0 = bor(lshift(g0, 2), rshift(g0, 4))
			b0 = bor(lshift(b0, 3), rshift(b0, 2))
			r1 = bor(lshift(r1, 3), rshift(r1, 2))
			g1 = bor(lshift(g1, 2), rshift(g1, 4))
			b1 = bor(lshift(b1, 3), rshift(b1, 2))

			-- Decode 4x4 block
			for py = 0, 3 do
				for px = 0, 3 do
					local x = bx * 4 + px
					local y = by * 4 + py

					if x < width and y < height then
						-- Get color index
						local index = band(rshift(indices, (py * 4 + px) * 2), 0x3)
						local r, g, b

						if index == 0 then
							r, g, b = r0, g0, b0
						elseif index == 1 then
							r, g, b = r1, g1, b1
						elseif index == 2 then
							r = math.floor((2 * r0 + r1) / 3)
							g = math.floor((2 * g0 + g1) / 3)
							b = math.floor((2 * b0 + b1) / 3)
						else
							r = math.floor((r0 + 2 * r1) / 3)
							g = math.floor((g0 + 2 * g1) / 3)
							b = math.floor((b0 + 2 * b1) / 3)
						end

						-- Get alpha index (3 bits per pixel)
						local pixel_idx = py * 4 + px
						local bit_offset = pixel_idx * 3
						local byte_idx = math.floor(bit_offset / 8)
						local bit_pos = bit_offset % 8
						local alpha_idx

						if bit_pos <= 5 then
							alpha_idx = band(rshift(alpha_indices[byte_idx], bit_pos), 0x7)
						else
							-- Index spans two bytes
							local low_bits = rshift(alpha_indices[byte_idx], bit_pos)
							local high_bits = lshift(alpha_indices[byte_idx + 1], 8 - bit_pos)
							alpha_idx = band(bor(low_bits, high_bits), 0x7)
						end

						-- Interpolate alpha
						local a

						if alpha_idx == 0 then
							a = a0
						elseif alpha_idx == 1 then
							a = a1
						elseif a0 > a1 then
							if alpha_idx == 2 then
								a = math.floor((6 * a0 + 1 * a1) / 7)
							elseif alpha_idx == 3 then
								a = math.floor((5 * a0 + 2 * a1) / 7)
							elseif alpha_idx == 4 then
								a = math.floor((4 * a0 + 3 * a1) / 7)
							elseif alpha_idx == 5 then
								a = math.floor((3 * a0 + 4 * a1) / 7)
							elseif alpha_idx == 6 then
								a = math.floor((2 * a0 + 5 * a1) / 7)
							else
								a = math.floor((1 * a0 + 6 * a1) / 7)
							end
						else
							if alpha_idx == 2 then
								a = math.floor((4 * a0 + 1 * a1) / 5)
							elseif alpha_idx == 3 then
								a = math.floor((3 * a0 + 2 * a1) / 5)
							elseif alpha_idx == 4 then
								a = math.floor((2 * a0 + 3 * a1) / 5)
							elseif alpha_idx == 5 then
								a = math.floor((1 * a0 + 4 * a1) / 5)
							elseif alpha_idx == 6 then
								a = 0
							else
								a = 255
							end
						end

						local offset = (y * width + x) * 4
						output[offset + 0] = r
						output[offset + 1] = g
						output[offset + 2] = b
						output[offset + 3] = a
					end
				end
			end
		end
	end

	return Buffer.New(output, output_size)
end

-- Convert uncompressed formats to RGBA8888
local function convert_to_rgba(input_buffer, width, height, format)
	local output_size = width * height * 4
	local output = ffi.new("uint8_t[?]", output_size)
	local pixel_count = width * height

	for i = 0, pixel_count - 1 do
		local offset = i * 4
		local r, g, b, a = 0, 0, 0, 255

		if format == VTF_IMAGE_FORMAT.RGBA8888 then
			r = input_buffer:ReadByte()
			g = input_buffer:ReadByte()
			b = input_buffer:ReadByte()
			a = input_buffer:ReadByte()
		elseif format == VTF_IMAGE_FORMAT.ABGR8888 then
			a = input_buffer:ReadByte()
			b = input_buffer:ReadByte()
			g = input_buffer:ReadByte()
			r = input_buffer:ReadByte()
		elseif format == VTF_IMAGE_FORMAT.RGB888 then
			r = input_buffer:ReadByte()
			g = input_buffer:ReadByte()
			b = input_buffer:ReadByte()
		elseif format == VTF_IMAGE_FORMAT.BGR888 or format == VTF_IMAGE_FORMAT.BGR888_BLUESCREEN then
			b = input_buffer:ReadByte()
			g = input_buffer:ReadByte()
			r = input_buffer:ReadByte()

			-- Handle bluescreen alpha
			if format == VTF_IMAGE_FORMAT.BGR888_BLUESCREEN and r == 0 and g == 0 and b == 255 then
				a = 0
			end
		elseif format == VTF_IMAGE_FORMAT.ARGB8888 then
			a = input_buffer:ReadByte()
			r = input_buffer:ReadByte()
			g = input_buffer:ReadByte()
			b = input_buffer:ReadByte()
		elseif format == VTF_IMAGE_FORMAT.BGRA8888 then
			b = input_buffer:ReadByte()
			g = input_buffer:ReadByte()
			r = input_buffer:ReadByte()
			a = input_buffer:ReadByte()
		elseif format == VTF_IMAGE_FORMAT.BGRX8888 then
			b = input_buffer:ReadByte()
			g = input_buffer:ReadByte()
			r = input_buffer:ReadByte()
			input_buffer:ReadByte() -- Skip X
		elseif format == VTF_IMAGE_FORMAT.I8 then
			local intensity = input_buffer:ReadByte()
			r, g, b = intensity, intensity, intensity
		elseif format == VTF_IMAGE_FORMAT.IA88 then
			local intensity = input_buffer:ReadByte()
			a = input_buffer:ReadByte()
			r, g, b = intensity, intensity, intensity
		elseif format == VTF_IMAGE_FORMAT.A8 then
			a = input_buffer:ReadByte()
			r, g, b = 255, 255, 255
		elseif format == VTF_IMAGE_FORMAT.RGB565 or format == VTF_IMAGE_FORMAT.BGR565 then
			local rgb565 = input_buffer:ReadU16LE()

			if format == VTF_IMAGE_FORMAT.RGB565 then
				r = band(rshift(rgb565, 11), 0x1F)
				g = band(rshift(rgb565, 5), 0x3F)
				b = band(rgb565, 0x1F)
			else
				b = band(rshift(rgb565, 11), 0x1F)
				g = band(rshift(rgb565, 5), 0x3F)
				r = band(rgb565, 0x1F)
			end

			r = bor(lshift(r, 3), rshift(r, 2))
			g = bor(lshift(g, 2), rshift(g, 4))
			b = bor(lshift(b, 3), rshift(b, 2))
		elseif format == VTF_IMAGE_FORMAT.BGRA5551 then
			local bgra5551 = input_buffer:ReadU16LE()
			b = band(rshift(bgra5551, 10), 0x1F)
			g = band(rshift(bgra5551, 5), 0x1F)
			r = band(bgra5551, 0x1F)
			a = band(bgra5551, 0x8000) ~= 0 and 255 or 0
			r = bor(lshift(r, 3), rshift(r, 2))
			g = bor(lshift(g, 3), rshift(g, 2))
			b = bor(lshift(b, 3), rshift(b, 2))
		elseif format == VTF_IMAGE_FORMAT.BGRA4444 then
			local bgra4444 = input_buffer:ReadU16LE()
			b = band(rshift(bgra4444, 12), 0xF)
			g = band(rshift(bgra4444, 8), 0xF)
			r = band(rshift(bgra4444, 4), 0xF)
			a = band(bgra4444, 0xF)
			r = bor(lshift(r, 4), r)
			g = bor(lshift(g, 4), g)
			b = bor(lshift(b, 4), b)
			a = bor(lshift(a, 4), a)
		else
			-- Unsupported format - return black pixel
			r, g, b, a = 0, 0, 0, 255
		end

		output[offset + 0] = r
		output[offset + 1] = g
		output[offset + 2] = b
		output[offset + 3] = a
	end

	return Buffer.New(output, output_size)
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

	-- Position at start of image data
	-- For version 7.3+, we need to skip to the actual image data
	-- The lowres image comes first (if present)
	local lowres_size = 0

	if header.lowres_width > 0 and header.lowres_height > 0 then
		lowres_size = compute_image_size(header.lowres_width, header.lowres_height, 1, header.lowres_image_format)

		if lowres_size then
			input_buffer:ReadBytes(lowres_size) -- Skip lowres image
		end
	end

	-- Get the main image (highest mipmap level)
	-- Mipmaps are stored from smallest to largest
	local width = header.width
	local height = header.height
	local format = header.image_format

	-- Skip smaller mipmaps and get to the largest one
	if header.mip_count > 1 then
		for mip = header.mip_count - 1, 1, -1 do
			local mip_width = math.max(1, math.floor(width / math.pow(2, mip)))
			local mip_height = math.max(1, math.floor(height / math.pow(2, mip)))
			local mip_size = compute_image_size(mip_width, mip_height, header.depth, format)

			if mip_size then input_buffer:ReadBytes(mip_size * header.frames) end
		end
	end

	-- Read the main image data for the first frame
	local image_size = compute_image_size(width, height, header.depth, format)

	if not image_size then
		return nil, "Unsupported image format: " .. tostring(format)
	end

	-- Extract image data for first frame only
	local image_data_start = input_buffer:GetPosition()
	local image_bytes = input_buffer:ReadBytes(image_size)
	local image_buffer = Buffer.New(ffi.cast("uint8_t*", image_bytes), #image_bytes)
	-- Decode/convert to RGBA
	local output_buffer

	if format == VTF_IMAGE_FORMAT.DXT1 or format == VTF_IMAGE_FORMAT.DXT1_ONEBITALPHA then
		output_buffer = decompress_dxt1(image_buffer, width, height)
	elseif format == VTF_IMAGE_FORMAT.DXT3 then
		output_buffer = decompress_dxt3(image_buffer, width, height)
	elseif format == VTF_IMAGE_FORMAT.DXT5 then
		output_buffer = decompress_dxt5(image_buffer, width, height)
	elseif not is_compressed(format) then
		output_buffer = convert_to_rgba(image_buffer, width, height, format)
	else
		return nil, "Unsupported compressed format: " .. tostring(format)
	end

	return {
		width = width,
		height = height,
		depth = header.depth,
		format = format,
		mip_count = header.mip_count,
		frames = header.frames,
		buffer = output_buffer,
	}
end

return vtf_decode
