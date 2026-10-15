local pvars = import("goluwa/cli/pvars.lua")
local commands = import("goluwa/cli/commands.lua")

commands.Add("hostname", function(line)
	network.SetHostName(line)
end)

commands.Add("EGP_ScrWH=arg_line", function() end)

if CLIENT then
	commands.Add("lua_openscript_cl", function(line)
		gine.env.include("lua/" .. line)
	end)

	if SOUND then
		pvars.Setup2{
			key = "volume",
			category = "Game",
			group = "Garry's Mod",
			default = 1,
			store = false,
			callback = function(val)
				audio.SetListenerGain(val)
			end,
		}

		pvars.Setup2{key = "snd_mute_losefocus", category = "Game", group = "Garry's Mod", default = 0, store = false}
	end

	pvars.Setup2{key = "cl_timeout", category = "Game", group = "Garry's Mod", default = 30, store = false}

	pvars.Setup2{key = "r_radiosity", category = "Game", group = "Garry's Mod", default = 0, store = false}

	pvars.Setup2{key = "developer", category = "Game", group = "Garry's Mod", default = 0, store = false}
end

if SERVER then
	commands.Add("lua_openscript", function(line)
		gine.env.include("lua/" .. line)
	end)
end
