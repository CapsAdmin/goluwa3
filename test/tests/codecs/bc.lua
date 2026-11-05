local T = import("test/environment.lua")
local ffi = require("ffi")
local bc = import("goluwa/codecs/bc.lua")

local function block(...)
	return ffi.new("uint8_t[?]", select("#", ...), {...})
end

T.Test("bc1 decodes the endpoints, the interpolated colors and one bit alpha", function()
	local src = block(0x00, 0xF8, 0x1F, 0x00, 0xE4, 0xE4, 0xE4, 0xE4)
	local out = bc.Decode("bc1", src, 4, 4)
	T(out[0])["=="](255)
	T(out[1])["=="](0)
	T(out[2])["=="](0)
	T(out[3])["=="](255)
	T(out[4 * 1 + 2])["=="](255)
	T(out[4 * 2 + 0])["=="](170)
	T(out[4 * 2 + 2])["=="](85)
	local punch = bc.Decode("bc1", block(0x1F, 0x00, 0x00, 0xF8, 0xFF, 0xFF, 0xFF, 0xFF), 4, 4)
	T(punch[3])["=="](0)
	T(punch[0])["=="](0)
end)

T.Test("bc3 takes alpha from the interpolated alpha block and clips partial blocks", function()
	local src = block(255, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0xF8, 0x1F, 0x00, 0, 0, 0, 0)
	local out = bc.Decode("bc3", src, 3, 2)
	T(ffi.sizeof(out))["=="](3 * 2 * 4)
	T(out[3])["=="](36)
	T(out[0])["=="](255)
	local opaque = bc.Decode("bc3", block(255, 0, 0, 0, 0, 0, 0, 0, 0x00, 0xF8, 0x1F, 0x00, 0, 0, 0, 0), 4, 4)
	T(opaque[3])["=="](255)
	local bc2 = bc.Decode("bc2", block(0x0F, 0, 0, 0, 0, 0, 0, 0, 0x00, 0xF8, 0x1F, 0x00, 0, 0, 0, 0), 4, 4)
	T(bc2[3])["=="](255)
	T(bc2[7])["=="](0)
end)

T.Test("bc4 and bc5 decode their channels from the endpoint palette", function()
	local bc4 = bc.Decode("bc4", block(255, 0, 0, 0, 0, 0, 0, 0), 4, 4)
	T(bc4[0])["=="](255)
	T(bc4[4 * 5])["=="](255)
	local indices = block(200, 40, 0x88, 0x00, 0x00, 0x00, 0x00, 0x00)
	T(bc.Decode("bc4", indices, 4, 4)[0])["=="](200)
	T(bc.Decode("bc4", indices, 4, 4)[4])["=="](40)
	local bc5 = bc.Decode("bc5", block(10, 0, 0, 0, 0, 0, 0, 0, 90, 0, 0, 0, 0, 0, 0, 0), 4, 4)
	T(bc5[0])["=="](10)
	T(bc5[1])["=="](90)
	T(bc5[2])["=="](0)
end)

T.Test("bc7 mode 6 decodes endpoints, p bits and interpolated indices", function()
	local bits = {}
	local position = 0

	local function put(value, count)
		for i = 0, count - 1 do
			bits[position] = bit.band(bit.rshift(value, i), 1)
			position = position + 1
		end
	end

	put(0x40, 7)

	for channel = 0, 3 do
		put(0, 7)
		put(127, 7)
	end

	put(0, 1)
	put(1, 1)

	for i = 0, 15 do
		put(i, i == 0 and 3 or 4)
	end

	local bytes = {}

	for byte = 0, 15 do
		local value = 0

		for i = 0, 7 do
			value = value + (bits[byte * 8 + i] or 0) * 2 ^ i
		end

		bytes[byte + 1] = value
	end

	local out = bc.Decode("bc7", block(unpack(bytes)), 4, 4)
	T(out[0])["=="](0)
	T(out[4 * 15])["=="](255)
	T(out[4 * 15 + 3])["=="](255)
	T(out[4 * 8])["=="](math.floor((30 * 0 + 34 * 255 + 32) / 64 + 0))
end)
