local engines = import("goluwa/engines.lua")
local event = import("goluwa/event.lua")
local pvars = import("goluwa/cli/pvars.lua")
local units = import("goluwa/source_engine/units.lua")
local CharacterMovement = import("lua/components/character_movement.lua")
local HULL_HEIGHT = 72 * units.meters
local ENGINE_SCALES = {}
local loaded_engine

local function apply()
	CharacterMovement.SetLevelScale(ENGINE_SCALES[loaded_engine] and ENGINE_SCALES[loaded_engine]:Get() or 1)
end

ENGINE_SCALES.cry = pvars.Setup2{
	key = "sv_cry_player_scale",
	category = "Game",
	group = "Server",
	prefix = "sv_",
	default = 1.8 / HULL_HEIGHT,
	help = "scale of players in Crysis levels, which are built for a 1.8 m player and the default is that (a 1.37 m Source player times this), multiplied by sv_player_scale",
	callback = function()
		if loaded_engine == "cry" then apply() end
	end,
}

event.AddListener("SceneLoad", "level_player_scale", function()
	loaded_engine = engines.loaded_map and engines.loaded_map:match("^(.-):")
	apply()
end)
