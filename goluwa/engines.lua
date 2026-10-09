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

commands.Add("map=string_trim|nil", function(name)
	if not name then
		for engine_name, engine in pairs(registered) do
			for _, map_name in ipairs(engine.List and engine.List() or {}) do
				print(engine_name .. ":" .. map_name)
			end
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
