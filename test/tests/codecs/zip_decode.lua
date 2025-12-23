local T = require("test.environment")
local vfs = require("filesystem.vfs")

T.Test("ZIP decode basic functionality", function()
	local ZIP_PATH = "/home/caps/projects/goluwa3/game/storage/temp_bsp.zip/materials/maps/gm_flatgrass/"
	-- Check if we can find files in the zip
	local files = vfs.Find(ZIP_PATH .. "/")
	T(files)["~="](nil)
	T(#files)[">="](4)
end)
