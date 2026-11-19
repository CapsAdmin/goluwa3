local commands = import("goluwa/cli/commands.lua")
local utility = import("goluwa/utility.lua")
local event = import("goluwa/event.lua")
local tasks = import("goluwa/tasks.lua")
local pvars = import("goluwa/cli/pvars.lua")
local loaders = {}
local registered = {}
local LOADER_MODULES = {
	source = "addons/source_loader/lua/source_loader/source_loader.lua",
	cry = "addons/crysis_loader/lua/crysis_loader/crysis_loader.lua",
}
pvars.StartGroup("Loader", "Load window", {prefix = "load_"})
local checked_games_pvar = pvars.Setup2{
	key = "load_checked_games",
	default = "",
	help = "games ticked in the load window as loader:id, comma separated. they are mounted at startup",
}
pvars.EndGroup()

function loaders.Register(name, loader)
	registered[name] = loader
end

function loaders.Find(name)
	local loader_name, rest = name:match("^(%w+):(.+)$")

	if loader_name and registered[loader_name] then
		local id, err = registered[loader_name].Find(rest)

		if not id then error(err, 0) end

		return registered[loader_name], id, loader_name
	end

	local found

	for loader_name, loader in pairs(registered) do
		local id = loader.Find(name)

		if id then
			if found then
				error(
					"map " .. name .. " exists in both " .. found.name .. " and " .. loader_name .. ", prefix it with the loader name",
					0
				)
			end

			found = {name = loader_name, loader = loader, id = id}
		end
	end

	if not found then error("could not find map " .. name, 0) end

	return found.loader, found.id, found.name
end

function loaders.Load(name)
	local loader, id, loader_name = loaders.Find(name)
	loaders.loaded_map = loader_name .. ":" .. id
	event.Call("SceneLoad", name)
	return tasks.RunBlocking(loader.Load, id)
end

local function get_sorted_loaders()
	local list = {}

	for loader_name, loader in pairs(registered) do
		list[#list + 1] = {name = loader_name, loader = loader}
	end

	table.sort(list, function(a, b)
		return a.name < b.name
	end)

	return list
end

function loaders.GetGames()
	local games = {}

	for _, entry in ipairs(get_sorted_loaders()) do
		for _, game in ipairs(entry.loader.GetGames and entry.loader.GetGames() or {}) do
			game.loader = entry.name
			games[#games + 1] = game
		end
	end

	return games
end

function loaders.GetMaps()
	local maps = {}

	for _, entry in ipairs(get_sorted_loaders()) do
		for _, map in ipairs(entry.loader.GetMaps and entry.loader.GetMaps() or {}) do
			map.loader = entry.name
			maps[#maps + 1] = map
		end
	end

	return maps
end

function loaders.GetMapThumbnail(map)
	local loader = registered[map.loader]

	if loader.GetMapThumbnail then return loader.GetMapThumbnail(map) end
end

function loaders.MountGame(loader_name, id)
	registered[loader_name].MountGame(id)
end

function loaders.UnmountGame(loader_name, id)
	registered[loader_name].UnmountGame(id)
end

local function get_game_key(loader_name, id)
	return loader_name .. ":" .. tostring(id)
end

function loaders.IsGameChecked(loader_name, id)
	local key = get_game_key(loader_name, id)

	for checked in checked_games_pvar:Get():gmatch("[^,]+") do
		if checked == key then return true end
	end

	return false
end

function loaders.SetGameChecked(loader_name, id, checked)
	if checked then
		loaders.MountGame(loader_name, id)
	else
		loaders.UnmountGame(loader_name, id)
	end

	local key = get_game_key(loader_name, id)
	local keys = {}

	for existing in checked_games_pvar:Get():gmatch("[^,]+") do
		if existing ~= key then keys[#keys + 1] = existing end
	end

	if checked then keys[#keys + 1] = key end

	checked_games_pvar:Set(table.concat(keys, ","))
end

function loaders.MountCheckedGames()
	for key in checked_games_pvar:Get():gmatch("[^,]+") do
		local loader_name, id = key:match("^(%w+):(.+)$")

		if loader_name and LOADER_MODULES[loader_name] then
			import(LOADER_MODULES[loader_name])
			local ok, err = pcall(loaders.MountGame, loader_name, tonumber(id) or id)

			if not ok then logf("could not mount %s: %s\n", key, tostring(err)) end
		end
	end
end

function loaders.LoadMap(map)
	return loaders.Load(map.loader .. ":" .. map.name)
end

commands.Add("map=string_trim|nil", function(name)
	if not name then
		for _, map in ipairs(loaders.GetMaps()) do
			print(map.loader .. ":" .. map.name)
		end

		return
	end

	utility.PushTimeWarning()
	loaders.Load(name)
	utility.PopTimeWarning("map " .. name, nil, "cmd")
end)

commands.Add("water_crysis_waves=boolean[true]", function(on)
	if on then
		import("addons/crysis_loader/lua/crysis_loader/water.lua").EnableCrysisWaves()
	else
		import("goluwa/render3d/water.lua").SetWaveBump(nil)
	end
end)

return loaders
