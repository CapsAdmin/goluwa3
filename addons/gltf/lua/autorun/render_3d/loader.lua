local loaders = import("goluwa/loaders.lua")
local gltf_scene_loader = import("lua/gltf_scene_loader.lua")
local gltf_scenes = import("lua/gltf_scenes.lua")
local GAME_ID = "scenes"
loaders.Register(
	"gltf",
	{
		Find = function(name)
			if gltf_scenes.FindIndex(name) then return name end

			return nil, "could not find gltf scene " .. name
		end,
		Load = function(name)
			local root_entity, gltf_data = gltf_scene_loader.Load(gltf_scenes.FindIndex(name), {name = name})

			if not root_entity then
				error("failed to load gltf scene " .. name .. ": " .. tostring(gltf_data), 0)
			end

			return root_entity
		end,
		GetGames = function()
			return {{id = GAME_ID, name = "glTF scenes", mounted = true, mountable = false}}
		end,
		GetMaps = function()
			local maps = {}

			for _, name in ipairs(gltf_scenes.GetNames()) do
				maps[#maps + 1] = {name = name, game = GAME_ID}
			end

			return maps
		end,
		GetMapThumbnail = function(map)
			return gltf_scenes.FindThumbnail(map.name)
		end,
	}
)
