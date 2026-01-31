local T = require("test.environment")
local tasks = require("tasks")
local commands = require("commands")
local steam = require("steam")

do -- todo, awkward require for steam.SetMap to exist on the steam library
	require("ecs.ecs")
	require("ecs.components.3d.model")
	require("ecs.components.3d.transform")
end

T.Test("map test", function()
	steam.MountSourceGame("gmod")
end)
