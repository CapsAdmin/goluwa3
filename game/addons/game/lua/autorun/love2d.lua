local line = import("goluwa/love/line.lua")
local commands = import("goluwa/commands.lua")

commands.Add("love=string", function(game)
	line.RunGame("/home/caps/projects/goluwa3/love_games/" .. game)
end)
