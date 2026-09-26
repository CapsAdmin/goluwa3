local T = import("test/environment.lua")
local ffi = require("ffi")
local dds = import("goluwa/codecs/dds.lua")
local Buffer = import("goluwa/structs/buffer.lua")

local function build_dds(fourcc, block)
	local header = ffi.new("uint32_t[32]")
	header[0] = 0x20534444 -- "DDS "
	header[1] = 124
	header[3] = 4 -- height
	header[4] = 4 -- width
	header[7] = 1 -- mip count
	header[19] = 32 -- pixel format size
	header[20] = 0x4 -- DDPF_FOURCC
	header[21] = fourcc
	local data = ffi.new("uint8_t[?]", 128 + 16)
	ffi.copy(data, header, 128)
	ffi.copy(data + 128, block, 16)
	return Buffer.New(data, 128 + 16)
end

local block = "\1\1\1\1\1\1\1\1\2\2\2\2\2\2\2\2"

T.Test("DDS ATI2 blocks are reordered to BC5 red then green", function()
	local decoded = dds.DecodeBuffer(build_dds(0x32495441, block))
	T(decoded.vulkan_format)["=="]("bc5_unorm_block")
	T(decoded.data[0])["=="](2)
	T(decoded.data[8])["=="](1)
end)

T.Test("DDS BC5U blocks are left as is", function()
	local decoded = dds.DecodeBuffer(build_dds(0x55354342, block))
	T(decoded.data[0])["=="](1)
	T(decoded.data[8])["=="](2)
end)
