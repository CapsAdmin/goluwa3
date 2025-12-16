do
	return
end

require("goluwa.global_environment")
local vfs = require("vfs")
local steam = require("steam")
local games = steam.GetSourceGames()

if not games[1] then return end

steam.MountSourceGame("gmod")
