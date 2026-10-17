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
local map_scene = import("goluwa/source_engine/map_scene.lua")
import("goluwa/source_engine/lights.lua")
local source_engine = {}

local function wait_for_map(path)
	local ok, result = pcall(bsp.Load, path)

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
		startup.Begin("bsp load")
		local data = wait_for_map(path)
		startup.End("bsp load")

		if not data then
			startup.End("source map load")

			return
		end

		startup.Begin("map translate")
		local scene_data = map_scene.Translate(data, name, path)
		startup.End("map translate")
		startup.Begin("scene spawn")
		scene.BeginSpawning()
		local ok, err = pcall(
			scene.Deserialize,
			scene_data,
			Entity.World,
			{yield_every = 128, skip_unavailable = not RENDER_3D}
		)
		scene.EndSpawning()
		startup.End("scene spawn")
		startup.End("source map load")

		if not ok then error(err, 0) end
	end

	task:Start()
end

engines.Register(
	"source",
	{
		Find = function(name)
			if tonumber(name) then return name end

			return game.FindMap(name)
		end,
		Load = source_engine.Load,
		List = function()
			local names = {}

			for _, path in ipairs(vfs.Find("maps/%.bsp$")) do
				names[#names + 1] = path:sub(0, -5)
			end

			return names
		end,
	}
)

return source_engine
