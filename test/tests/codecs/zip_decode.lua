local T = require("test.environment")
local vfs = require("filesystem.vfs")
local ZIP_PATH = "/home/caps/projects/goluwa3/game/storage/temp_bsp.zip/materials/maps/gm_flatgrass/"

if not vfs.Exists(ZIP_PATH) then
	T.Pending("ZIP decode basic functionality", function() end)

	return
end

T.Test("ZIP decode basic functionality", function()
	-- Check if we can find files in the zip
	local files = vfs.Find(ZIP_PATH .. "/")
	T(files)["~="](nil)
	T(#files)[">="](0)
end)
