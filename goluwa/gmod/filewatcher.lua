local filewatcher = library()
local event = import("goluwa/event.lua")

local function is_gmod_example_path(path)
	return path:find("game/addons/game/lua/examples/gmod/", nil, true) ~= nil
end

local function get_gine_environment()
	local gine = _G.gine or import.loaded["goluwa/gmod/gine.lua"]

	if not gine.env then
		gine.Initialize("sandbox")
		gine.Run()
	end

	return gine.env
end

function filewatcher.IsGModExamplePath(path)
	return is_gmod_example_path(path)
end

event.AddListener("FileWatcherGetEnvironment", "gine_filewatcher_environment", function(path)
	if not is_gmod_example_path(path) then return end

	return get_gine_environment()
end)

event.AddListener("FileSaved", "hotreload_gmod_examples", function(path, code, from_terminal, env)
	if not is_gmod_example_path(path) then return end

	local func, err = loadstring(code, "@" .. path)

	if not func then
		io.write("failed to compile ", path, ": ", tostring(err), "\n")
		return false
	end

	setfenv(func, env or get_gine_environment())

	local ok, run_err = xpcall(func, debug.traceback)

	if not ok then
		io.write("failed to reload ", path, ": ", tostring(run_err), "\n")
		return false
	end

	io.write("ran ", path, " in gine environment\n")
	return false
end)

return filewatcher
