local T = import("test/environment.lua")
local ffi = require("ffi")
local dds = import("goluwa/codecs/dds.lua")
local Buffer = import("goluwa/structs/buffer.lua")

local function build_dds(fourcc, block)
	local header = ffi.new("uint32_t[32]")
	header[0] = 0x20534444
	header[1] = 124
	header[3] = 4
	header[4] = 4
	header[7] = 1
	header[19] = 32
	header[20] = 0x4
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

T.Test("DDS CryEngine attached alpha decodes as a single channel image", function()
	local attached = ffi.new("uint8_t[?]", 128 + 16)
	local attached_header = ffi.new("uint32_t[32]")
	attached_header[0] = 0x20534444
	attached_header[1] = 124
	attached_header[3] = 4
	attached_header[4] = 4
	attached_header[7] = 1
	attached_header[19] = 32
	attached_header[20] = 0x4
	attached_header[21] = 28
	ffi.copy(attached, attached_header, 128)

	for i = 0, 15 do
		attached[128 + i] = i * 16
	end

	local main = build_dds(0x32495441, block)
	local size = 128 + 16 + 4 + 8 + (128 + 16) + 4
	local data = ffi.new("uint8_t[?]", size)
	ffi.copy(data, main:GetBuffer(), 128 + 16)
	ffi.cast("uint32_t *", data)[31] = 0x43525946
	local chunks = data + 128 + 16
	ffi.copy(chunks, "CExtAttC", 8)
	ffi.cast("uint32_t *", chunks + 8)[0] = 128 + 16
	ffi.copy(chunks + 12, attached, 128 + 16)
	ffi.copy(chunks + 12 + 128 + 16, "CEnd", 4)
	local decoded = dds.DecodeBuffer(Buffer.New(data, size))
	T(decoded.vulkan_format)["=="]("bc5_unorm_block")
	T(decoded.attached_image.vulkan_format)["=="]("r8_unorm")
	T(decoded.attached_image.data[1])["=="](16)
	T(decoded.attached_image.data[15])["=="](240)
end)
