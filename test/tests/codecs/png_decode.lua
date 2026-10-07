local T = import("test/environment.lua")
local ffi = require("ffi")
local Buffer = import("goluwa/structs/buffer.lua")
local png = import("goluwa/codecs/png.lua")
local resource = import("goluwa/resource.lua")

local function load_png_file(path)
	local file = assert(io.open(path, "rb"), "Could not open PNG file: " .. path)
	local file_data = file:read("*a")
	file:close()
	local file_buffer_data = ffi.new("uint8_t[?]", #file_data)
	ffi.copy(file_buffer_data, file_data, #file_data)
	return Buffer.New(file_buffer_data, #file_data)
end

T.Test("PNG decode basic functionality", function()
	local file_buffer = load_png_file(
		resource.Download(
			"https://github.com/CapsAdmin/goluwa-assets/raw/refs/heads/master/extras/textures/pac.png"
		):Get()
	)
	local img = png.DecodeBuffer(file_buffer)
	T(img.width)[">"](0)
	T(img.height)[">"](0)
	T(img.depth)["~="](nil)
	T(img.colorType)["~="](nil)
	T(img.buffer:GetSize())[">"](0)
	T(img.buffer:GetSize())["=="](img.width * img.height * 4)
end)

T.Test("PNG decode capsadmin.png average color", function()
	local file_buffer = load_png_file(
		resource.Download(
			"https://github.com/CapsAdmin/goluwa-assets/raw/refs/heads/master/extras/textures/pac.png"
		):Get()
	)
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
	local file_buffer = load_png_file(
		resource.Download(
			"https://github.com/CapsAdmin/goluwa-assets/raw/refs/heads/master/extras/textures/pac.png"
		):Get()
	)
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

T.Test("PNG encode writes the adler32 of the data when the first sum wraps to zero", function()
	local width, height = 1000, 22
	local size = width * height * 3
	local pixels = ffi.new("uint8_t[?]", size)

	for i = 0, 255 do
		pixels[i] = 255
	end

	pixels[256] = 240
	local file = png.Encode(width, height, "rgb")
	file:write(pixels)
	local data = file:getData()
	local s1, s2 = 1, 0

	for y = 0, height - 1 do
		s2 = (s2 + s1) % 65521

		for x = 0, width * 3 - 1 do
			s1 = (s1 + pixels[y * width * 3 + x]) % 65521
			s2 = (s2 + s1) % 65521
		end
	end

	T(s1)["=="](0)
	local idat = data:find("IDAT", 1, true)
	local length = data:byte(idat - 4) * 16777216 + data:byte(idat - 3) * 65536 + data:byte(idat - 2) * 256 + data:byte(idat - 1)
	local last = idat + 4 + length - 1
	local stored = data:byte(last - 3) * 16777216 + data:byte(last - 2) * 65536 + data:byte(last - 1) * 256 + data:byte(last)
	T(stored)["=="](s2 * 65536 + s1)
end)
