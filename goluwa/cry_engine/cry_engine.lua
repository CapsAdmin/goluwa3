local engines = import("goluwa/engines.lua")
local steam = import("goluwa/steam/steam.lua")
local startup = import("goluwa/startup.lua")
local scene = import("goluwa/entities/scene.lua")
local Entity = import("goluwa/entities/entity.lua")
local game = import("goluwa/cry_engine/game.lua")
local level = import("goluwa/cry_engine/level.lua")
local cry_scene = import("goluwa/cry_engine/scene.lua")
local cry_engine = {}

function cry_engine.Load(name, options)
	options = options or {}
	local level_dir = assert(game.ResolveLevelDirectory(name))
	local level_name = level_dir:match("/([^/]+)/$") or level_dir
	local level_path = level_dir:match("/Game/Levels/(.+)/$") or level_dir
	startup.Begin("cry level load")
	local data = level.Load(level_dir)
	startup.End("cry level load")
	startup.Begin("cry scene translate")
	local scene_data = cry_scene.Translate(data, level_name, level_path, options)
	startup.End("cry scene translate")
	scene.Clear()
	startup.Begin("cry scene spawn")

	if options.sync then
		scene.Deserialize(scene_data, Entity.World)
	else
		scene.SpawnAsync(
			scene_data,
			Entity.World,
			nil,
			function(...)
				startup.End("cry scene spawn")

				if options.done then options.done(...) end
			end
		)
	end

	return data
end

engines.Register(
	"cry",
	{
		Find = function(name)
			for _, candidate in ipairs{name, "Multiplayer/" .. name} do
				if game.ResolveLevelDirectory(candidate) then return candidate end
			end

			return nil, "could not find Crysis level " .. name
		end,
		Load = cry_engine.Load,
		GetGames = function()
			local cry_game = game.FindCryGame()

			if not cry_game then return {} end

			return {
				{
					id = cry_game.appid,
					name = cry_game.name,
					image = steam.GetGameImage(cry_game.appid, "header"),
					mounted = true,
				},
			}
		end,
		GetMaps = function()
			local maps = {}
			local cry_game = game.FindCryGame()

			for i, level in ipairs(game.ListLevels()) do
				maps[i] = {name = level, game = cry_game.appid, mounted = true}
			end

			return maps
		end,
		GetMapThumbnail = function(map)
			return game.GetLevelThumbnail(map.name)
		end,
	}
)
return cry_engine
