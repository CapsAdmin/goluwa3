local vfs = require("vfs")
require("model_loader")
local steam = require("steam")
local games = steam.GetSourceGames()

if not games[1] then return end

steam.MountSourceGame("gmod")
steam.LoadMap("maps/gm_flatgrass.bsp")
