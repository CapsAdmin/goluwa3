require("goluwa.global_environment")
_G.VERBOSE_TESTS = true
local T = require("test.t")
local ffi = require("ffi")
local dxt = require("helpers.dxt")

-- Test 1: Simple 4x4 block with known pattern
T.test("DXT1 decompress single block - solid red", function()
	-- Create a DXT1 block for solid red
	-- Color0 = RGB(255, 0, 0) = 0xF800 in RGB565
	-- Color1 = RGB(0, 0, 0) = 0x0000 in RGB565
	-- All pixels use index 0 (color0)
	local block = ffi.new(
		"uint8_t[8]",
		{
			0x00,
			0xF8, -- color0: 0xF800 (red in RGB565)
			0x00,
			0x00, -- color1: 0x0000 (black)
			0x00,
			0x00,
			0x00,
			0x00, -- all pixels use index 0
		}
	)
	local output = ffi.new("uint8_t[64]") -- 4x4 * 4 bytes
	local decompress_func = dxt.decompress_dxt1_block or
		function(b, o)
			-- Inline the block decompress for testing
			local ptr = ffi.cast("uint8_t*", b)
			local out = ffi.cast("uint8_t*", o)
			local bit = require("bit")
			local color0 = ptr[0] + ptr[1] * 256
			local color1 = ptr[2] + ptr[3] * 256
			local r0 = bit.rshift(bit.band(color0, 0xF800), 11)
			local g0 = bit.rshift(bit.band(color0, 0x07E0), 5)
			local b0 = bit.band(color0, 0x001F)
			r0 = bit.lshift(r0, 3) + bit.rshift(r0, 2)
			g0 = bit.lshift(g0, 2) + bit.rshift(g0, 4)
			b0 = bit.lshift(b0, 3) + bit.rshift(b0, 2)

			-- All pixels should be color0
			for i = 0, 15 do
				out[i * 4 + 0] = r0
				out[i * 4 + 1] = g0
				out[i * 4 + 2] = b0
				out[i * 4 + 3] = 255
			end
		end
	local rgba = dxt.decompress_dxt1(block, 4, 4)
	-- Debug: print what we actually got
	print(string.format("First pixel: R=%d G=%d B=%d A=%d", rgba[0], rgba[1], rgba[2], rgba[3]))
	-- Check first pixel is red
	T(rgba[0])["=="](255) -- R (31 in 5-bit converts to 255 in 8-bit)
	T(rgba[1])["=="](0) -- G
	T(rgba[2])["=="](0) -- B
	T(rgba[3])["=="](255) -- A
end)

-- Test 2: 4x4 block with green color (RGB)
T.test("DXT1 decompress - solid green (RGB)", function()
	-- Green = RGB(0, 255, 0) = 0x07E0 in RGB565
	local block = ffi.new(
		"uint8_t[8]",
		{
			0xE0,
			0x07, -- color0: 0x07E0 (green in RGB565)
			0x00,
			0x00, -- color1: black
			0x00,
			0x00,
			0x00,
			0x00, -- all pixels use index 0
		}
	)
	local rgba = dxt.decompress_dxt1(block, 4, 4)
	-- Check first pixel is green
	T(rgba[0])["=="](0) -- R
	T(rgba[1])["=="](255) -- G (252 rounded)
	T(rgba[2])["=="](0) -- B
	T(rgba[3])["=="](255) -- A
	print(string.format("Green pixel: R=%d G=%d B=%d", rgba[0], rgba[1], rgba[2]))
end)

-- Test 3: 4x4 block with green color in BGR format (VTF style)
T.test("DXT1 decompress - solid green (BGR format)", function()
	-- In BGR565, green is still in the middle, but R and B are swapped in bit positions
	-- Green = BGR(0, 255, 0) = 0x07E0 in BGR565 (same as RGB!)
	-- But to test BGR parsing, let's use a color that's different in BGR vs RGB
	-- Red in BGR = 0x001F (in the low 5 bits instead of high 5 bits)
	local block = ffi.new(
		"uint8_t[8]",
		{
			0x1F,
			0x00, -- color0: 0x001F (red in BGR565 = blue in RGB565)
			0x00,
			0x00, -- color1: black
			0x00,
			0x00,
			0x00,
			0x00, -- all pixels use index 0
		}
	)
	local rgba = dxt.decompress_dxt1_bgr(block, 4, 4)
	print(string.format("BGR red pixel: R=%d G=%d B=%d", rgba[0], rgba[1], rgba[2]))
	-- In BGR mode, 0x001F should decode as red (not blue)
	T(rgba[0])["=="](255) -- R
	T(rgba[1])["=="](0) -- G
	T(rgba[2])["=="](0) -- B
	T(rgba[3])["=="](255) -- A
end)

-- Test 4: Actual VTF texture first block
T.test("DXT1 decompress - VTF grass texture first block", function()
	local Buffer = require("structs.buffer")
	local vtf_decode = require("file_formats.vtf.decode")
	local vfs = require("vfs")
	local VTF = "/home/caps/.steam/steam/steamapps/common/GarrysMod/garrysmod/garrysmod_dir.vpk/materials/gm_construct/grass1.vtf"
	local file = vfs.Open(VTF)

	if not file then
		print("Could not open VTF file, skipping test")
		return
	end

	local file_data = file:ReadAll()
	file:Close()
	local file_buffer_data = ffi.new("uint8_t[?]", #file_data)
	ffi.copy(file_buffer_data, file_data, #file_data)
	local file_buffer = Buffer.New(file_buffer_data, #file_data)
	local img = vtf_decode(file_buffer)
	-- Get the first block of the largest mip
	local first_block_offset = img.mip_info[1].offset
	local block_data = ffi.cast("uint8_t*", img.data) + first_block_offset
	print("\nFirst block of grass texture (raw bytes):")
	print(
		string.format(
			"  %02x %02x %02x %02x %02x %02x %02x %02x",
			block_data[0],
			block_data[1],
			block_data[2],
			block_data[3],
			block_data[4],
			block_data[5],
			block_data[6],
			block_data[7]
		)
	)
	-- Decompress using BGR mode
	local rgba = dxt.decompress_dxt1_bgr(block_data, 4, 4)
	-- Print first few pixels
	print("First 4 pixels decoded:")

	for i = 0, 3 do
		local offset = i * 4
		print(
			string.format(
				"  Pixel %d: R=%3d G=%3d B=%3d A=%3d",
				i,
				rgba[offset],
				rgba[offset + 1],
				rgba[offset + 2],
				rgba[offset + 3]
			)
		)
	end

	-- Grass should be primarily green/brown, so check that green channel is significant
	local has_green = false

	for i = 0, 15 do
		local offset = i * 4

		if rgba[offset + 1] > 100 then -- Green channel
			has_green = true

			break
		end
	end

	T(has_green)["=="](true)
end)

require("goluwa.main")()
