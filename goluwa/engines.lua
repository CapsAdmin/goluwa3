local commands = import("goluwa/cli/commands.lua")
local utility = import("goluwa/utility.lua")
local event = import("goluwa/event.lua")
local engines = {}
local registered = {}

function engines.Register(name, engine)
	registered[name] = engine
end

function engines.Find(name)
	local engine_name, rest = name:match("^(%w+):(.+)$")

	if engine_name and registered[engine_name] then
		local id, err = registered[engine_name].Find(rest)

		if not id then error(err, 0) end

		return registered[engine_name], id
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

	return found.engine, found.id
end

function engines.Load(name)
	local engine, id = engines.Find(name)
	event.Call("SceneLoad", name)
	return engine.Load(id)
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

-- the games an engine can load maps from, {engine, id, name, image, mounted, mountable}. a mountable game costs something to mount and lists more maps once it is
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

-- {engine, name, game, mounted} for every map that can be listed without loading anything
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

-- a vfs path to a picture of the map or nil
function engines.GetMapThumbnail(map)
	local engine = registered[map.engine]
	return engine.GetMapThumbnail and engine.GetMapThumbnail(map)
end

function engines.MountGame(engine_name, id)
	registered[engine_name].MountGame(id)
end

function engines.UnmountGame(engine_name, id)
	registered[engine_name].UnmountGame(id)
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
