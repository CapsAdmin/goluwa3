local prefab = import("goluwa/entities/prefab.lua")
local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local outfit_source = {}
outfit_source.Models = {
	"models/player/zombie_classic.mdl",
	"models/player/combine_soldier.mdl",
	"models/player/kleiner.mdl",
	"models/player/eli.mdl",
	"models/characters/eli/eli.vmdl_c",
	"models/characters/gman/gman.vmdl_c",
	"models/characters/alyx/alyx.vmdl_c",
}
outfit_source.Model = outfit_source.Models[3]
outfit_source.Name = "player_outfit_source"

function outfit_source.IsAvailable()
	return steam.IsSourceGameMounted("gmod") == true
end

function outfit_source.IsModelAvailable(model)
	return not model:find("%.vmdl_c$") or vfs.IsFile(model)
end

function outfit_source.GetLabel(model)
	local name = model:match("([^/]+)%.[^.]+$")
	return model:find("%.vmdl_c$") and name .. " (alyx)" or name
end

function outfit_source.GetDefinition()
	return {
		inputs = {
			{
				Name = "Model",
				Type = "string",
				Default = outfit_source.Model,
				Targets = {{Node = "model", Component = "model", Property = "ModelPath"}},
			},
		},
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
					eyes = {AutoBlink = true},
					source_pose = {Profile = "gmod_player", Mirror = true},
				},
			},
		},
	}
end

prefab.Register(outfit_source.Name, outfit_source.GetDefinition()).builtin = true
return outfit_source
