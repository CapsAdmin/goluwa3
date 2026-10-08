local ffi = require("ffi")

local function u16(n)
	return string.char(n % 256, math.floor(n / 256) % 256)
end

local function u32(n)
	return u16(n % 65536) .. u16(math.floor(n / 65536))
end

local function f32(n)
	local f = ffi.new("float[1]", n)
	return ffi.string(f, 4)
end

return function(colors)
	local header = "VTF\0" .. u32(7) .. u32(2) .. u32(80) .. u16(4) .. u16(4) .. u32(0) .. u16(#colors) .. u16(0) .. "\0\0\0\0" .. f32(1) .. f32(1) .. f32(1) .. "\0\0\0\0" .. f32(1) .. u32(13) .. "\1" .. u32(0xFFFFFFFF) .. "\0\0" .. u16(1)
	header = header .. string.rep("\0", 80 - #header)
	local data = ""

	for _, c in ipairs(colors) do
		data = data .. u16(c) .. u16(c) .. u32(0)
	end

	return header .. data
end
