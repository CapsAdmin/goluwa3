local utility = import("goluwa/utility.lua")
local commands = import("goluwa/commands.lua")
local event = import("goluwa/event.lua")
local gine = import("lua/gine.lua")

commands.Add("ginit=string[sandbox],boolean", function(gamemode, skip_addons)
	utility.PushTimeWarning()
	gine.Initialize(gamemode, skip_addons)
	utility.PopTimeWarning("gine.Initialize", 0)
	utility.PushTimeWarning()
	gine.Run(skip_addons)
	utility.PopTimeWarning("gine.Run", 0)
end)

event.AddListener("KeyInput", function(key, press)
	if key == "q" and press then commands.RunString("ginit") end
end)

commands.Add("glua=arg_line", function(code)
	if not gine.env then gine.Initialize() end

	local func = assert(loadstring(code))
	setfenv(func, gine.env)
	print(func())
end)
