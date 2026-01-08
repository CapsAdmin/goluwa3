local vk = require("bindings.vk")

if not pcall(vk.find_library) then
	print("Vulkan library not available, skipping polygon_3d comprehensive tests.")
	return
end

local T = require("test.environment")
local tasks = require("tasks")
local commands = require("commands")
local steam = require("steam")

do -- todo, awkward require for steam.SetMap to exist on the steam library
	require("ecs")
	require("components.model")
	require("components.transform")
end

T.Test("get games", function()
	local games = steam.GetSourceGames()
	table.print(games, 1)
end)

T.Pending("map test", function()
	steam.MountSourceGame("gmod")
	tasks.WaitAll(5)
	commands.RunString("map gm_construct")
	tasks.WaitAll(5)
end)
