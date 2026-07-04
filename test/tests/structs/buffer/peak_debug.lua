local T = import("test/environment.lua")
local ffi = require("ffi")
local Buffer = import("goluwa/structs/buffer.lua")

T.Test("Buffer PeakByte peeks and rewinds", function()
	local buf = ffi.new("uint8_t[5]", {10, 20, 30, 40, 50})
	local buffer = Buffer.New(buf, 5)
	local byte = buffer:PeakByte()
	T(byte)["=="](10)
	-- Position should be unchanged after peek
	T(buffer:GetPosition())["=="](0)
	byte = buffer:PeakByte()
	T(byte)["=="](10)
end)

T.Test("Buffer PeakBytes peeks multiple bytes and rewinds", function()
	local buf = ffi.new("uint8_t[5]", {10, 20, 30, 40, 50})
	local buffer = Buffer.New(buf, 5)
	local str = buffer:PeakBytes(3)
	T(str)["=="]("\x0A\x14\x1E")
	-- Position should be unchanged after peek
	T(buffer:GetPosition())["=="](0)
	-- Can still read from the same position
	T(buffer:ReadByte())["=="](10)
end)

T.Test("Buffer GetDebugString returns hex dump", function()
	local buf = ffi.new("uint8_t[4]", {0xDE, 0xAD, 0xBE, 0xEF})
	local buffer = Buffer.New(buf, 4)
	local hex = buffer:GetDebugString()
	T(type(hex))["=="]("string")
	T(#hex > 0)["=="](true)
	-- Should contain the hex representation
	T(hex:find("DE", 1, true) or hex:find("de", 1, true))
end)

T.Test("Buffer GetDebugString preserves position", function()
	local buf = ffi.new("uint8_t[4]", {1, 2, 3, 4})
	local buffer = Buffer.New(buf, 4)
	buffer:Advance(2)
	T(buffer:GetPosition())["=="](2)
	buffer:GetDebugString()
	T(buffer:GetPosition())["=="](2)
end)
