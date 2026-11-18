local T = import("test/environment.lua")
local dds = import("goluwa/codecs/dds.lua")
local cutout_texture = import("goluwa/render/cutout_texture.lua")

T.Test("cutout_texture reads the alpha of every mip of a bc3 dds", function()
	-- a0 255, a1 0, texels 0 to 7 use index 0 and texels 8 to 15 index 1
	local block = string.char(255, 0, 0, 0, 0, 0x49, 0x92, 0x24) .. string.rep("\0", 8)
	local levels = cutout_texture.DDSAlphaLevels(dds.Encode("BC3_UNORM", 4, 4, {block, block, block}))
	T(#levels)["=="](3)
	T(levels[1].width)["=="](4)
	T(levels[3].width)["=="](1)
	T(levels[1].alpha[0])["=="](255)
	T(levels[1].alpha[7])["=="](255)
	T(levels[1].alpha[8])["=="](0)
	T(levels[1].alpha[15])["=="](0)
	-- a 2x2 mip covers the first two rows of its block, which are all index 0
	T(levels[2].alpha[3])["=="](255)
end)

T.Test("cutout_texture reads punch through alpha from a bc1 dds", function()
	-- color0 <= color1 selects the mode where index 3 is transparent, the first row uses it
	local block = string.char(0, 0, 255, 255, 0xff, 0, 0, 0)
	local levels = cutout_texture.DDSAlphaLevels(dds.Encode("BC1_UNORM", 4, 4, {block}))
	T(levels[1].alpha[0])["=="](0)
	T(levels[1].alpha[3])["=="](0)
	T(levels[1].alpha[4])["=="](255)
end)

T.Test("cutout_texture does not read the alpha of other formats", function()
	T(cutout_texture.DDSAlphaLevels(dds.Encode("BC7_UNORM", 4, 4, {string.rep("\0", 16)})))["=="](nil)
end)
