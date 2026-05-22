local utility = import("goluwa/utility.lua")
local commands = import("goluwa/commands.lua")
local event = import("goluwa/event.lua")

commands.Add("ginit=string[sandbox],boolean", function(gamemode, skip_addons)
	local gine = import("lua/gine.lua")
	utility.PushTimeWarning()
	gine.Initialize(gamemode, skip_addons)
	utility.PopTimeWarning("gine.Initialize", 0)
	utility.PushTimeWarning()
	gine.Run(skip_addons)
	utility.PopTimeWarning("gine.Run", 0)
end)

commands.Add("glua=arg_line", function(code)
	local gine = import("lua/gine.lua")

	if not gine.env then gine.Initialize() end

	local func = assert(loadstring(code))
	setfenv(func, gine.env)
	print(func())
end)
