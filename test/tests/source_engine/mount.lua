local T = import("test/environment.lua")
local tasks = import("goluwa/tasks.lua")
local commands = import("goluwa/commands.lua")
local steam = import("goluwa/steam.lua")

T.Test("map test", function()
	steam.MountSourceGame("gmod")
end)
