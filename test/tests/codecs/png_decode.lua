local T = require("test.environment")
local ffi = require("ffi")
local Buffer = require("structs.buffer")
local png = require("codecs.png")
local resource = require("resource")

-- Helper to load PNG file into buffer
local function load_png_file(path)
	local file = assert(io.open(path, "rb"), "Could not open PNG file: " .. path)
	local file_data = file:read("*a")
	file:close()
	local file_buffer_data = ffi.new("uint8_t[?]", #file_data)
	ffi.copy(file_buffer_data, file_data, #file_data)
	return Buffer.New(file_buffer_data, #file_data)
end


T.Test("PNG decode basic functionality", function()
	local file_buffer = load_png_file(resource.Download("https://github.com/CapsAdmin/goluwa-assets/raw/refs/heads/master/extras/textures/pac.png"):Get())
	local img = png.DecodeBuffer(file_buffer)
	T(img.width)[">"](0)
	T(img.height)[">"](0)
	T(img.depth)["~="](nil)
	T(img.colorType)["~="](nil)
	T(img.buffer:GetSize())[">"](0)
	T(img.buffer:GetSize())["=="](img.width * img.height * 4)
end)

T.Test("PNG decode capsadmin.png average color", function()
	local file_buffer = load_png_file(resource.Download("https://github.com/CapsAdmin/goluwa-assets/raw/refs/heads/master/extras/textures/pac.png"):Get())
	local img = png.DecodeBuffer(file_buffer)
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

	T(non_black_pixels)[">"](0)
	local max_channel = math.max(max_r, max_g, max_b)
	T(max_channel)[">"](0)
end)

T.Test("PNG decode RGB image has correct alpha channel", function()
	local file_buffer = load_png_file(resource.Download("https://github.com/CapsAdmin/goluwa-assets/raw/refs/heads/master/extras/textures/pac.png"):Get())
	local img = png.DecodeBuffer(file_buffer)
	T(img.colorType)["=="](6)
	img.buffer:SetPosition(0)
	local pixel_count = img.width * img.height
	local alpha_count = 0

	for i = 1, pixel_count do
		local r = img.buffer:ReadByte()
		local g = img.buffer:ReadByte()
		local b = img.buffer:ReadByte()
		local a = img.buffer:ReadByte()

		if a ~= 255 then alpha_count = alpha_count + 1 end
	end

	T(alpha_count)["=="](26818)
end)
