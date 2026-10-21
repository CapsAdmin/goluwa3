local T = import("test/environment.lua")
local ffi = require("ffi")
local bmp = import("goluwa/codecs/bmp.lua")
local int32 = ffi.typeof("int32_t[1]")
local int16 = ffi.typeof("int16_t[1]")

local function le32(value)
	return ffi.string(int32(value), 4)
end

local function le16(value)
	return ffi.string(int16(value), 2)
end

local function pack_bmp(width, height, rows)
	local stride = math.ceil(width * 3 / 4) * 4
	local pixels = {}

	for _, row in ipairs(rows) do
		pixels[#pixels + 1] = row .. ("\0"):rep(stride - #row)
	end

	local pixel_data = table.concat(pixels)
	local header = "BM" .. le32(54 + #pixel_data) .. le32(0) .. le32(54)
	local info = le32(40) .. le32(width) .. le32(height) .. le16(1) .. le16(24) .. le32(0) .. le32(#pixel_data) .. le32(2835) .. le32(2835) .. le32(0) .. le32(0)
	return header .. info .. pixel_data
end

T.Test("BMP decode 24 bit rows and padding", function()
	local img = bmp.Decode(pack_bmp(2, 2, {"\0\0\255\0\255\0", "\255\0\0\255\255\255"}))
	T(img.width)["=="](2)
	T(img.height)["=="](2)
	local p = img.data
	T(p[0])["=="](255)
	T(p[1])["=="](0)
	T(p[2])["=="](0)
	T(p[3])["=="](255)
	T(p[4])["=="](0)
	T(p[5])["=="](255)
	T(p[8])["=="](0)
	T(p[10])["=="](255)
	T(p[12])["=="](255)
	T(p[13])["=="](255)
	T(p[14])["=="](255)
end)

T.Test("BMP decode top down", function()
	local img = bmp.Decode(pack_bmp(1, -2, {"\255\0\0", "\0\0\255"}))
	T(img.height)["=="](2)
	T(img.data[0])["=="](255)
	T(img.data[2])["=="](0)
	T(img.data[4])["=="](0)
	T(img.data[6])["=="](255)
end)
