local T = require("test.environment")
local vfs = require("filesystem.vfs")
local ZIP_PATH = "/home/caps/projects/goluwa3/game/storage/temp_bsp.zip/materials/maps/gm_flatgrass/"

T.Test("ZIP decode basic functionality", function()
	if not vfs.Exists(ZIP_PATH) then
		return T.Unavailable("ZIP file not found at " .. ZIP_PATH)
	end
	-- Check if we can find files in the zip
	local files = vfs.Find(ZIP_PATH .. "/")
	T(files)["~="](nil)
	T(#files)[">="](0)
end)
