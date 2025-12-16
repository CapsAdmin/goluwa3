local ffi = require("ffi")
local bit = require("bit")
local dxt = {}

-- Decompress a single DXT1 block (4x4 pixels) to RGBA
-- block_data: pointer to 8 bytes of DXT1 data
-- output: pointer to 64 bytes of RGBA output (4x4 * 4 bytes per pixel)
local function decompress_dxt1_block(block_data, output)
	local ptr = ffi.cast("uint8_t*", block_data)
	local out = ffi.cast("uint8_t*", output)
	-- Read two 16-bit colors (little endian)
	local color0 = ptr[0] + ptr[1] * 256
	local color1 = ptr[2] + ptr[3] * 256
	-- Extract RGB565 components
	local r0 = bit.rshift(bit.band(color0, 0xF800), 11)
	local g0 = bit.rshift(bit.band(color0, 0x07E0), 5)
	local b0 = bit.band(color0, 0x001F)
	local r1 = bit.rshift(bit.band(color1, 0xF800), 11)
	local g1 = bit.rshift(bit.band(color1, 0x07E0), 5)
	local b1 = bit.band(color1, 0x001F)
	-- Convert from 5/6 bit to 8 bit
	r0 = bit.lshift(r0, 3) + bit.rshift(r0, 2)
	g0 = bit.lshift(g0, 2) + bit.rshift(g0, 4)
	b0 = bit.lshift(b0, 3) + bit.rshift(b0, 2)
	r1 = bit.lshift(r1, 3) + bit.rshift(r1, 2)
	g1 = bit.lshift(g1, 2) + bit.rshift(g1, 4)
	b1 = bit.lshift(b1, 3) + bit.rshift(b1, 2)
	-- Build color palette
	local colors = {}
	colors[0] = {r0, g0, b0, 255}
	colors[1] = {r1, g1, b1, 255}

	if color0 > color1 then
		-- 4-color mode (no alpha)
		colors[2] = {
			math.floor((2 * r0 + r1) / 3),
			math.floor((2 * g0 + g1) / 3),
			math.floor((2 * b0 + b1) / 3),
			255,
		}
		colors[3] = {
			math.floor((r0 + 2 * r1) / 3),
			math.floor((g0 + 2 * g1) / 3),
			math.floor((b0 + 2 * b1) / 3),
			255,
		}
	else
		-- 3-color mode (1-bit alpha)
		colors[2] = {
			math.floor((r0 + r1) / 2),
			math.floor((g0 + g1) / 2),
			math.floor((b0 + b1) / 2),
			255,
		}
		colors[3] = {0, 0, 0, 0} -- transparent black
	end

	-- Decode 4x4 pixel indices (2 bits per pixel, 4 bytes total)
	for row = 0, 3 do
		local indices_byte = ptr[4 + row]

		for col = 0, 3 do
			-- Extract 2-bit index for this pixel
			local index = bit.band(bit.rshift(indices_byte, col * 2), 0x03)
			local color = colors[index]
			-- Write RGBA
			local pixel_offset = (row * 4 + col) * 4
			out[pixel_offset + 0] = color[1] -- R
			out[pixel_offset + 1] = color[2] -- G
			out[pixel_offset + 2] = color[3] -- B
			out[pixel_offset + 3] = color[4] -- A
		end
	end
end

-- Decompress full DXT1 image to RGBA
-- data: pointer to DXT1 compressed data
-- width, height: dimensions in pixels (must be multiples of 4)
-- Returns: ffi buffer containing RGBA data
function dxt.decompress_dxt1(data, width, height)
	local blocks_x = math.floor((width + 3) / 4)
	local blocks_y = math.floor((height + 3) / 4)
	local output_size = width * height * 4
	local output = ffi.new("uint8_t[?]", output_size)
	local input_ptr = ffi.cast("uint8_t*", data)

	for by = 0, blocks_y - 1 do
		for bx = 0, blocks_x - 1 do
			local block_index = by * blocks_x + bx
			local block_data = input_ptr + block_index * 8
			-- Decompress this 4x4 block
			local block_output = ffi.new("uint8_t[64]")
			decompress_dxt1_block(block_data, block_output)

			-- Copy block to output image
			for row = 0, 3 do
				for col = 0, 3 do
					local px = bx * 4 + col
					local py = by * 4 + row

					if px < width and py < height then
						local src_offset = (row * 4 + col) * 4
						local dst_offset = (py * width + px) * 4
						output[dst_offset + 0] = block_output[src_offset + 0]
						output[dst_offset + 1] = block_output[src_offset + 1]
						output[dst_offset + 2] = block_output[src_offset + 2]
						output[dst_offset + 3] = block_output[src_offset + 3]
					end
				end
			end
		end
	end

	return output
end

-- Same but for BGR565 order (VTF format)
function dxt.decompress_dxt1_bgr(data, width, height)
	local blocks_x = math.floor((width + 3) / 4)
	local blocks_y = math.floor((height + 3) / 4)
	local output_size = width * height * 4
	local output = ffi.new("uint8_t[?]", output_size)
	local input_ptr = ffi.cast("uint8_t*", data)

	for by = 0, blocks_y - 1 do
		for bx = 0, blocks_x - 1 do
			local block_index = by * blocks_x + bx
			local block_ptr = input_ptr + block_index * 8
			-- Read two 16-bit colors (little endian)
			local color0 = block_ptr[0] + block_ptr[1] * 256
			local color1 = block_ptr[2] + block_ptr[3] * 256
			-- Extract BGR565 components (note: BGR order!)
			local b0 = bit.rshift(bit.band(color0, 0xF800), 11)
			local g0 = bit.rshift(bit.band(color0, 0x07E0), 5)
			local r0 = bit.band(color0, 0x001F)
			local b1 = bit.rshift(bit.band(color1, 0xF800), 11)
			local g1 = bit.rshift(bit.band(color1, 0x07E0), 5)
			local r1 = bit.band(color1, 0x001F)
			-- Convert from 5/6 bit to 8 bit
			r0 = bit.lshift(r0, 3) + bit.rshift(r0, 2)
			g0 = bit.lshift(g0, 2) + bit.rshift(g0, 4)
			b0 = bit.lshift(b0, 3) + bit.rshift(b0, 2)
			r1 = bit.lshift(r1, 3) + bit.rshift(r1, 2)
			g1 = bit.lshift(g1, 2) + bit.rshift(g1, 4)
			b1 = bit.lshift(b1, 3) + bit.rshift(b1, 2)
			-- Build color palette
			local colors = {}
			colors[0] = {r0, g0, b0, 255}
			colors[1] = {r1, g1, b1, 255}

			if color0 > color1 then
				colors[2] = {
					math.floor((2 * r0 + r1) / 3),
					math.floor((2 * g0 + g1) / 3),
					math.floor((2 * b0 + b1) / 3),
					255,
				}
				colors[3] = {
					math.floor((r0 + 2 * r1) / 3),
					math.floor((g0 + 2 * g1) / 3),
					math.floor((b0 + 2 * b1) / 3),
					255,
				}
			else
				colors[2] = {
					math.floor((r0 + r1) / 2),
					math.floor((g0 + g1) / 2),
					math.floor((b0 + b1) / 2),
					255,
				}
				colors[3] = {0, 0, 0, 0}
			end

			-- Decode 4x4 pixel indices
			for row = 0, 3 do
				local indices_byte = block_ptr[4 + row]

				for col = 0, 3 do
					local px = bx * 4 + col
					local py = by * 4 + row

					if px < width and py < height then
						local index = bit.band(bit.rshift(indices_byte, col * 2), 0x03)
						local color = colors[index]
						local dst_offset = (py * width + px) * 4
						output[dst_offset + 0] = color[1]
						output[dst_offset + 1] = color[2]
						output[dst_offset + 2] = color[3]
						output[dst_offset + 3] = color[4]
					end
				end
			end
		end
	end

	return output
end

return dxt
