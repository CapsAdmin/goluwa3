local gine = ... or _G.gine
local system = import("goluwa/system.lua")
local game = gine.env.game

local function get_startup_map()
	local args = system.GetStartupArguments()

	for i = 1, #args do
		if args[i] == "+map" and args[i + 1] and args[i + 1] ~= "" then
			return args[i + 1]
		end
	end

	return "gm_construct"
end

function game.GetMap()
	return get_startup_map()
end

function game.GetIPAddress()
	return "0.0.0.0:27015"
end

function game.IsDedicated()
	return #system.GetWindows() == 0
end