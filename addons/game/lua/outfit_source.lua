local prefab = import("goluwa/entities/prefab.lua")
local outfit_source = {}
outfit_source.Model = "models/player/kleiner.mdl"
outfit_source.Name = "player_outfit_source"

function outfit_source.GetDefinition()
	return {
		inputs = {},
		entities = {
			{guid = "root", components = {}},
			{
				guid = "model",
				parent = "root",
				properties = {Name = "model"},
				components = {
					transform = {},
					model = {ModelPath = outfit_source.Model},
					animator = {},
					source_pose = {Profile = "gmod_player", Mirror = true},
				},
			},
		},
	}
end

prefab.Register(outfit_source.Name, outfit_source.GetDefinition()).builtin = true
return outfit_source
