local hotreload = {}
local fs = import("goluwa/filesystem/fs.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local last_content = {}

function hotreload.GetFileEnvironment(path)
	return event.Call("FileWatcherGetEnvironment", path) or _G
end

local function run_hotreload_code(code)
	local func, err = load(code)

	if not func then
		io.write("failed to load hotreload code:", err, "\n")
		return false
	end

	local trimmed = code:match("^%s*(.-)%s*$")
	io.write("running hotreload code:\n", trimmed, "\n")
	func()
	return true
end

local function run_hotreload_config(path, code)
	local hotreload_code = code:match("%-%-%[%[HOTRELOAD(.-)%]%]")

	if hotreload_code then return run_hotreload_code(hotreload_code) end

	local dir = path:match("(.+)/")

	if not dir then return false end

	while dir do
		local hotreload_path = dir .. "/hotreload.lua"
		local hotreload_file_code = fs.read_file(hotreload_path)

		if hotreload_file_code then
			io.write("found hotreload code in ", hotreload_path, "\n")
			return run_hotreload_code(hotreload_file_code)
		end

		dir = dir:match("(.+)/")
	end

	return false
end

local function default_reload(path)
	local content, err

	for i = 1, 30 do
		content, err = fs.read_file(path)

		if content ~= "" then
			break
		elseif i == 30 then
			io.write("failed to read file after multiple attempts:", err, "\n")
			return
		end

		system.Sleep(0.001)
	end

	if not content then
		io.write("failed to read file:", err, "\n")
		return
	end

	local func, err = loadstring(content, "@" .. path)

	if not func then
		io.write("failed to compile ", path, ": ", tostring(err), "\n")
		return
	end

	setfenv(func, hotreload.GetFileEnvironment(path))
	local ok, err = xpcall(func, debug.traceback)

	if not ok then
		io.write("failed to reload ", path, ": ", tostring(err), "\n")
		return
	end

	io.write("ran ", path, "\n")
end

do
	local MAX_MODULES = 100
	local never_reload = {
		["goluwa/import.lua"] = true,
		["goluwa/require.lua"] = true,
		["goluwa/filesystem/watcher.lua"] = true,
	}

	local function get_dependents(module_path, kept)
		local out = {}
		local strong = import.strong

		for importer in pairs(import.importers[module_path] or {}) do
			if
				import.loaded[importer] ~= nil and
				not never_reload[importer] and
				(
					not kept or
					strong[importer] and
					strong[importer][module_path]
				)
			then
				out[#out + 1] = importer
			end
		end

		return out
	end

	local function is_kept(module_path)
		local module = import.loaded[module_path]
		return type(module) == "table" and (module.Type ~= nil or import:IsNamespace(module_path))
	end

	local function imports_any(module_path, set)
		local visited = {}
		local stack = {module_path}

		while #stack > 0 do
			local current = table.remove(stack)

			for dependency in pairs(import.imports[current] or {}) do
				if set[dependency] then return true end

				if not visited[dependency] then
					visited[dependency] = true
					stack[#stack + 1] = dependency
				end
			end
		end

		return false
	end

	function hotreload.GetModulePath(path)
		path = import.SourceToPath("@" .. path)

		if path and import.loaded[path] ~= nil then return path end
	end

	function hotreload.PredictModuleReloads(module_path)
		local found = {[module_path] = true}
		local queue = {module_path}
		local count = 1

		while #queue > 0 do
			local current = table.remove(queue)

			for _, importer in ipairs(get_dependents(current, is_kept(current))) do
				if not found[importer] then
					found[importer] = true
					count = count + 1
					queue[#queue + 1] = importer
				end
			end
		end

		return found, count
	end

	function hotreload.ReloadModule(module_path)
		local predicted, count = hotreload.PredictModuleReloads(module_path)

		local cascade = count <= MAX_MODULES

		if not cascade then
			if not is_kept(module_path) then
				io.write(
					"not reloading ",
					module_path,
					": it is replaced by a new value and ",
					count - 1,
					" modules depend on it, restart instead\n"
				)

				return
			end

			io.write(
				"reloading only ",
				module_path,
				": ",
				count - 1,
				" modules depend on it, those that took values from it while loading keep the old ones\n"
			)
		end

		jit.flush()
		local pending = {[module_path] = true}
		local done = {}
		local reloaded = {}

		while next(pending) do
			local current

			for candidate in pairs(pending) do
				local others = {}

				for other in pairs(pending) do
					if other ~= candidate then others[other] = true end
				end

				if not imports_any(candidate, others) then
					current = candidate

					break
				end
			end

			current = current or next(pending)
			pending[current] = nil
			done[current] = true
			_G.HOTRELOAD = true
			local kept, err = import:Reload(current)

			if kept == nil then
				io.write("failed to reload ", current, ": ", tostring(err), "\n")

				break
			end

			reloaded[#reloaded + 1] = current

			if cascade then
				for _, importer in ipairs(get_dependents(current, kept)) do
					if not done[importer] then pending[importer] = true end
				end
			end
		end

		jit.flush()

		if #reloaded == 0 then return end

		_G.HOTRELOAD = true
		io.write("reloaded ", table.concat(reloaded, ", "), "\n")
		event.Call("ModulesReloaded", reloaded)
	end
end

local function on_reload(path, from_terminal)
	if not path:ends_with(".lua") and not path:ends_with(".nlua") then return end

	if path:find("hotreload.lua", nil, true) then
		local code = fs.read_file(path)

		if code then
			local func, err = load(code)

			if not func then io.write(path, " failed to compile: ", err, "\n") end
		end

		return
	end

	local code, err = fs.read_file(path)

	if not code and err then
		io.write("failed to read file:", err, "\n")
		return nil, nil
	end

	local identical = false

	if last_content[path] == code then identical = true end

	local file_name = path:match("([^/]+)$") or path
	io.write(
		"reloading ",
		file_name,
		identical and " (content is identical from last time)" or "",
		"\n"
	)

	if not from_terminal then _G.HOTRELOAD = true end

	_G.path = path
	_G.code = code
	_G.file_save_env = hotreload.GetFileEnvironment(path)
	local file_save_result = event.Call("FileSaved", path, code, from_terminal, _G.file_save_env)

	if file_save_result ~= nil then
		_G.HOTRELOAD = nil
		_G.path = nil
		_G.code = nil
		_G.file_save_env = nil
		last_content[path] = code
		return code, identical
	end

	if hotreload.OnReload(path, code) ~= false then
		local module_path = hotreload.GetModulePath(path)

		if run_hotreload_config(path, code) then
		elseif module_path then
			hotreload.ReloadModule(module_path)
		else
			default_reload(path)
		end
	end

	_G.HOTRELOAD = nil
	_G.path = nil
	_G.code = nil
	_G.file_save_env = nil
	last_content[path] = code
	return code, identical
end

function hotreload.OnReload(path, code) end

function hotreload.Reload(path, from_terminal)
	return on_reload(path, from_terminal)
end

function hotreload.Start()
	hotreload.Stop()

	if not fs.watch then
		logn("fs.watch is not available, hotreload cannot work")
		return
	end

	local last_reloaded = {}
	hotreload.stop_watch = fs.watch(
		{"./goluwa", "./addons"},
		function(path, what)
			if what ~= "modified" then return end

			if not path:ends_with(".lua") and not path:ends_with(".nlua") then return end

			if last_reloaded[path] and last_reloaded[path] > system.GetElapsedTime() then
				return
			end

			last_reloaded[path] = system.GetElapsedTime() + 0.2
			hotreload.Reload(path)
			last_reloaded[path] = system.GetElapsedTime() + 0.2
		end,
		true,
		{".git", "gmod/src", "love/games"}
	)
end

function hotreload.Stop()
	if hotreload.stop_watch then
		hotreload.stop_watch()
		hotreload.stop_watch = nil
	end
end

return hotreload
