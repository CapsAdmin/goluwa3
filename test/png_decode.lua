local test = require("test.gambarina")
local ffi = require("ffi")
local Buffer = require("helpers.buffer")
local png = require("helpers.png")

-- Helper to load PNG file into buffer
local function load_png_file(path)
	local file = assert(io.open(path, "rb"), "Could not open PNG file: " .. path)
	local file_data = file:read("*a")
	file:close()
	local file_buffer_data = ffi.new("uint8_t[?]", #file_data)
	ffi.copy(file_buffer_data, file_data, #file_data)
	return Buffer.New(file_buffer_data, #file_data)
end

test("PNG decode basic functionality", function()
	local file_buffer = load_png_file("examples/vulkan/capsadmin.png")
	local img = png.decode(file_buffer)
	ok(img.width > 0, "width should be greater than 0")
	ok(img.height > 0, "height should be greater than 0")
	ok(img.depth ~= nil, "bit depth should be set")
	ok(img.colorType ~= nil, "color type should be set")
	ok(img.buffer:GetSize() > 0, "buffer should contain data")
	-- Verify expected buffer size (RGBA = 4 bytes per pixel)
	local expected_size = img.width * img.height * 4
	ok(
		img.buffer:GetSize() == expected_size,
		"buffer size should match width * height * 4"
	)
end)

test("PNG decode capsadmin.png average color", function()
	local file_buffer = load_png_file("examples/vulkan/capsadmin.png")
	local img = png.decode(file_buffer)
	img.buffer:SetPosition(0)
	local pixel_count = img.width * img.height
	local non_black_pixels = 0
	local max_r, max_g, max_b = 0, 0, 0

	for i = 1, pixel_count do
		local r = img.buffer:ReadByte()
		local g = img.buffer:ReadByte()
		local b = img.buffer:ReadByte()
		local a = img.buffer:ReadByte()

		if r > 0 or g > 0 or b > 0 then non_black_pixels = non_black_pixels + 1 end

		max_r = math.max(max_r, r)
		max_g = math.max(max_g, g)
		max_b = math.max(max_b, b)
	end

	-- The image should have some non-black pixels
	ok(non_black_pixels > 0, "image should have some non-black pixels")
	-- At least one channel should have non-zero max value
	local max_channel = math.max(max_r, max_g, max_b)
	ok(max_channel > 0, "at least one pixel should have a non-zero color value")
end)

test("PNG decode RGB image has correct alpha channel", function()
	local file_buffer = load_png_file("examples/vulkan/capsadmin.png")
	local img = png.decode(file_buffer)
	-- capsadmin.png is RGB (colorType 2), so all alpha should be 255
	ok(img.colorType == 2, "capsadmin.png should be RGB (colorType 2)")
	img.buffer:SetPosition(0)
	local pixel_count = img.width * img.height
	local incorrect_alpha_count = 0

	for i = 1, pixel_count do
		local r = img.buffer:ReadByte()
		local g = img.buffer:ReadByte()
		local b = img.buffer:ReadByte()
		local a = img.buffer:ReadByte()

		if a ~= 255 then incorrect_alpha_count = incorrect_alpha_count + 1 end
	end

	ok(
		incorrect_alpha_count == 0,
		"all pixels in RGB image should have alpha=255, found " .. incorrect_alpha_count .. " incorrect"
	)
end)
