local T = require("test.environment")
local tasks = require("tasks")
local commands = require("commands")
local steam = require("steam")

T.Test("map test", function()
	steam.MountSourceGame("gmod")
end)
