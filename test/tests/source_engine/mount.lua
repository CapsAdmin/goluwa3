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
	require("components.3d.model")
	require("components.3d.transform")
end

T.Test("map test", function()
	steam.MountSourceGame("gmod")
end)
