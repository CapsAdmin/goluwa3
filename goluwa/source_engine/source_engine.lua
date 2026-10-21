local startup = import("goluwa/startup.lua")
local vfs = import("goluwa/vfs.lua")
local file_path = import("goluwa/filesystem/path.lua")
local codec = import("goluwa/codec.lua")
local tasks = import("goluwa/tasks.lua")
local utility = import("goluwa/utility.lua")
local steam = import("goluwa/steam/steam.lua")
local scene = import("goluwa/entities/scene.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local Entity = import("goluwa/entities/entity.lua")
local engines = import("goluwa/engines.lua")
local game = import("goluwa/source_engine/game.lua")
local bsp = import("goluwa/source_engine/bsp.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local map_scene = import("goluwa/source_engine/map_scene.lua")
import("goluwa/source_engine/lights.lua")
local source_engine = {}

local function wait_for_map(path, skybox)
	local ok, result = pcall(bsp.Load, path, skybox)

	if not ok then
		wlog("failed to load map " .. path .. ": " .. tostring(result))
		return nil
	end

	return result
end

function source_engine.Load(name)
	if tonumber(name) then
		local workshop_id = tonumber(name)
		local info = codec.LookupInFile("luadata", "workshop_maps.cfg", workshop_id)

		if info and vfs.IsFile(info.path) then
			steam.MountSourceGame(info.appid)
			vfs.Mount(info.path, "maps/")
			return source_engine.Load(info.name)
		end

		steam.DownloadWorkshop(workshop_id, function(path, info)
			local map_name = info.publishedfiledetails[1].filename:match(".+/(.+)%.bsp")
			local appid = info.publishedfiledetails[1].creator_app_id
			codec.StoreInFile(
				"luadata",
				"workshop_maps.cfg",
				workshop_id,
				{path = path, name = map_name, appid = appid}
			)
			steam.MountSourceGame(appid)
			vfs.Mount(path, "maps/")
			source_engine.Load(map_name)
		end)

		return
	end

	local path = game.GetMapPath(name)
	startup.Begin("mount source games")
	game.EnsureMounted(path)
	startup.End("mount source games")
	scene.Clear()
	local task = tasks.CreateTask()
	task:SetName("source map load")
	scene_loading.HoldTask(task)
	startup.Begin("source map load")

	function task:OnStart()
		scene.BeginSpawning()
		local ok, err = pcall(source_engine.SpawnChain, name, path)
		scene.EndSpawning()
		startup.End("source map load")

		if not ok then error(err, 0) end
	end

	task:Start()
end

function source_engine.GetLandmarks(entities)
	local landmarks = {}

	for _, info in pairs(entities) do
		if info.classname == "info_landmark" and info.targetname and info.origin then
			landmarks[info.targetname] = info.origin
		end
	end

	return landmarks
end

function source_engine.GetChangeLevels(entities)
	local changes = {}

	for _, info in pairs(entities) do
		if info.classname == "trigger_changelevel" and info.map and info.landmark then
			changes[#changes + 1] = {map = info.map:lower(), landmark = info.landmark}
		end
	end

	return changes
end

function source_engine.FindChain(name, path)
	local group = name:match("^(.-)_%d+%a*$") or name
	local chain = {{name = name, path = path, offset = Vec3(0, 0, 0)}}
	local placed = {[name] = true}
	local head = 1

	while chain[head] do
		local entry = chain[head]
		head = head + 1
		local entities = bsp.LoadEntities(entry.path)
		local landmarks = source_engine.GetLandmarks(entities)

		for _, change in ipairs(source_engine.GetChangeLevels(entities)) do
			if
				not placed[change.map] and
				change.map:match("^(.-)_%d+%a*$") == group and
				landmarks[change.landmark]
			then
				local next_path = game.GetMapPath(change.map)
				game.EnsureMounted(next_path)

				if vfs.IsFile(next_path) then
					local ok, next_entities = pcall(bsp.LoadEntities, next_path)
					local next_landmark = ok and source_engine.GetLandmarks(next_entities)[change.landmark]

					if next_landmark then
						placed[change.map] = true
						logn("chaining ", change.map, " via ", change.landmark)
						chain[#chain + 1] = {
							name = change.map,
							path = next_path,
							offset = entry.offset + landmarks[change.landmark] - next_landmark,
						}
					end
				end
			end
		end
	end

	return chain
end

function source_engine.SpawnChain(name, path)
	local chain = source_engine.FindChain(name, path)

	for i, entry in ipairs(chain) do
		startup.Begin("bsp load")
		local data = wait_for_map(entry.path, #chain == 1)
		startup.End("bsp load")

		if not data then
			if i == 1 then error("failed to load " .. entry.name, 0) end
		else
			startup.Begin("map translate")
			local scene_data = map_scene.Translate(data, entry.name, entry.path, i > 1 and entry.offset or nil)
			startup.End("map translate")
			startup.Begin("scene spawn")
			scene.Deserialize(
				scene_data,
				Entity.World,
				{yield_every = 128, skip_unavailable = not RENDER_3D}
			)
			startup.End("scene spawn")
		end
	end
end

engines.Register(
	"source",
	{
		Find = function(name)
			if tonumber(name) then return name end

			return game.FindMap(name)
		end,
		Load = source_engine.Load,
		GetGames = function()
			local games = {}

			for i, info in ipairs(game.GetMountableGames()) do
				games[i] = {
					id = info.filesystem.steamappid,
					name = game.GetGameName(info),
					image = game.GetGameImage(info),
					mounted = steam.IsSourceGameMounted(info),
					mountable = true,
				}
			end

			return games
		end,
		MountGame = function(id)
			assert(steam.MountSourceGame(id))
		end,
		UnmountGame = function(id)
			assert(steam.UnmountSourceGame(id))
		end,
		GetMaps = game.GetMaps,
		GetMapThumbnail = function(map)
			return game.GetMapThumbnail(map.name, map.game and steam.FindSourceGame(map.game))
		end,
	}
)

return source_engine
