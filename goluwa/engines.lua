local commands = import("goluwa/cli/commands.lua")
local utility = import("goluwa/utility.lua")
local event = import("goluwa/event.lua")
local tasks = import("goluwa/tasks.lua")
local pvars = import("goluwa/cli/pvars.lua")
local engines = {}
local registered = {}
local ENGINE_MODULES = {
	source = "goluwa/source_engine/source_engine.lua",
	cry = "goluwa/cry_engine/cry_engine.lua",
}
pvars.StartGroup("Engine", "Load window", {prefix = "load_"})
local checked_games_pvar = pvars.Setup2{
	key = "load_checked_games",
	default = "",
	help = "games ticked in the load window as engine:id, comma separated. they are mounted at startup",
}
pvars.EndGroup()

function engines.Register(name, engine)
	registered[name] = engine
end

function engines.Find(name)
	local engine_name, rest = name:match("^(%w+):(.+)$")

	if engine_name and registered[engine_name] then
		local id, err = registered[engine_name].Find(rest)

		if not id then error(err, 0) end

		return registered[engine_name], id, engine_name
	end

	local found

	for engine_name, engine in pairs(registered) do
		local id = engine.Find(name)

		if id then
			if found then
				error(
					"map " .. name .. " exists in both " .. found.name .. " and " .. engine_name .. ", prefix it with the engine name",
					0
				)
			end

			found = {name = engine_name, engine = engine, id = id}
		end
	end

	if not found then error("could not find map " .. name, 0) end

	return found.engine, found.id, found.name
end

function engines.Load(name)
	local engine, id, engine_name = engines.Find(name)
	engines.loaded_map = engine_name .. ":" .. id
	event.Call("SceneLoad", name)
	return tasks.RunBlocking(engine.Load, id)
end

local function get_sorted_engines()
	local list = {}

	for engine_name, engine in pairs(registered) do
		list[#list + 1] = {name = engine_name, engine = engine}
	end

	table.sort(list, function(a, b)
		return a.name < b.name
	end)

	return list
end

function engines.GetGames()
	local games = {}

	for _, entry in ipairs(get_sorted_engines()) do
		for _, game in ipairs(entry.engine.GetGames and entry.engine.GetGames() or {}) do
			game.engine = entry.name
			games[#games + 1] = game
		end
	end

	return games
end

function engines.GetMaps()
	local maps = {}

	for _, entry in ipairs(get_sorted_engines()) do
		for _, map in ipairs(entry.engine.GetMaps and entry.engine.GetMaps() or {}) do
			map.engine = entry.name
			maps[#maps + 1] = map
		end
	end

	return maps
end

function engines.GetMapThumbnail(map)
	local engine = registered[map.engine]

	if engine.GetMapThumbnail then return engine.GetMapThumbnail(map) end
end

function engines.MountGame(engine_name, id)
	registered[engine_name].MountGame(id)
end

function engines.UnmountGame(engine_name, id)
	registered[engine_name].UnmountGame(id)
end

local function get_game_key(engine_name, id)
	return engine_name .. ":" .. tostring(id)
end

function engines.IsGameChecked(engine_name, id)
	local key = get_game_key(engine_name, id)

	for checked in checked_games_pvar:Get():gmatch("[^,]+") do
		if checked == key then return true end
	end

	return false
end

function engines.SetGameChecked(engine_name, id, checked)
	if checked then
		engines.MountGame(engine_name, id)
	else
		engines.UnmountGame(engine_name, id)
	end

	local key = get_game_key(engine_name, id)
	local keys = {}

	for existing in checked_games_pvar:Get():gmatch("[^,]+") do
		if existing ~= key then keys[#keys + 1] = existing end
	end

	if checked then keys[#keys + 1] = key end

	checked_games_pvar:Set(table.concat(keys, ","))
end

function engines.MountCheckedGames()
	for key in checked_games_pvar:Get():gmatch("[^,]+") do
		local engine_name, id = key:match("^(%w+):(.+)$")

		if engine_name and ENGINE_MODULES[engine_name] then
			import(ENGINE_MODULES[engine_name])
			local ok, err = pcall(engines.MountGame, engine_name, tonumber(id) or id)

			if not ok then logf("could not mount %s: %s\n", key, tostring(err)) end
		end
	end
end

function engines.LoadMap(map)
	return engines.Load(map.engine .. ":" .. map.name)
end

commands.Add("map=string_trim|nil", function(name)
	if not name then
		for _, map in ipairs(engines.GetMaps()) do
			print(map.engine .. ":" .. map.name)
		end

		return
	end

	utility.PushTimeWarning()
	engines.Load(name)
	utility.PopTimeWarning("map " .. name, nil, "cmd")
end)

commands.Add("water_crysis_waves=boolean[true]", function(on)
	if on then
		import("goluwa/cry_engine/water.lua").EnableCrysisWaves()
	else
		import("goluwa/render3d/water.lua").SetWaveBump(nil)
	end
end)

return engines
