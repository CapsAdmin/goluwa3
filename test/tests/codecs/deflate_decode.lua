local T = import("test/environment.lua")
local deflate = import("goluwa/codecs/deflate.lua")

T.Test("deflate code length repeat across the literal and distance tables", function()
	-- dynamic block whose final code length repeat (17, three zeros) covers
	-- literal 257 and both distance codes; zlib's encoder never emits this,
	-- crytek's pak encoder does
	local raw = "\x0d\xc1\xa1\x00\x00\x00\x00\x00\x20\xd6\xfc\x25\x1a\x02"
	T(deflate.Decode(raw, "raw"):ReadBytes(1))["=="]("a")
end)
