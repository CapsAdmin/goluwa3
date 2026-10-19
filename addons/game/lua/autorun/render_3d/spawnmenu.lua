local input = import("goluwa/input.lua")
local spawnmenu = import("lua/spawnmenu.lua")
input.Bind("q", "+spawnmenu", spawnmenu.Hold)
input.Bind("q", "-spawnmenu", spawnmenu.Release)
