local T = import("test/environment.lua")
local vtf = import("goluwa/codecs/vtf.lua")
local Buffer = import("goluwa/structs/buffer.lua")
local ffi = require("ffi")
local build = import("test/vtf_frames.lua")

T.Test("vtf decodes every frame, one after another", function()
	local colors = {0xF800, 0x07E0, 0x001F, 0xFFFF}
	local str = build(colors)
	local meta, data = vtf.DecodeBuffer(Buffer.New(str, #str))
	T(meta.frames)["=="](4)
	T(meta.frame_stride)["=="](8)
	T(meta.data_size)["=="](8)
	T(ffi.sizeof(data))["=="](32)

	for i, c in ipairs(colors) do
		local p = ffi.cast("uint8_t *", data) + (i - 1) * meta.frame_stride
		T(p[0] + p[1] * 256)["=="](c)
	end
end)

T.Test("vtf without frames still decodes as one", function()
	local str = build({0xF800})
	local meta, data = vtf.DecodeBuffer(Buffer.New(str, #str))
	T(meta.frames)["=="](1)
	T(ffi.sizeof(data))["=="](8)
end)
