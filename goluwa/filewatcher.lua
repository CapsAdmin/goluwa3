local hotreload = library()
local fs = require("fs")
local event = require("event")
local last_content = {}

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
	local func, err = loadfile(path)

	if not func then
		io.write("failed to compile ", path, ": ", tostring(err), "\n")
		return
	end

	local ok, err = pcall(func)

	if not ok then
		io.write("failed to reload ", path, ": ", tostring(err), "\n")
		return
	end

	io.write("ran  ", path, "\n")
end

local function on_reload(path)
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

	-- Check if content is identical to avoid unnecessary reloads
	local identical = false

	if last_content[path] == code then identical = true end

	-- Get file name for logging
	local file_name = path:match("([^/]+)$") or path
	io.write(
		"reloading ",
		file_name,
		identical and " (content is identical from last time)" or "",
		"\n"
	)
	-- Set global variables for hotreload code to use
	_G.HOTRELOAD = true
	_G.path = path
	_G.code = code

	-- Try custom OnReload first
	if hotreload.OnReload(path, code) ~= false then
		-- If OnReload didn't return false, try hotreload config
		if not run_hotreload_config(path, code) then
			-- Otherwise do default reload
			default_reload(path)
		end
	end

	-- Clean up globals
	_G.HOTRELOAD = nil
	_G.path = nil
	_G.code = nil
	return code, identical
end

function hotreload.OnReload(path, code) end

function hotreload.Start()
	hotreload.Stop()
	local last_reloaded = {}
	hotreload.stop_watch = fs.watch(
		".",
		function(path, what)
			if what ~= "modified" then return end

			if not path:ends_with(".lua") and not path:ends_with(".nlua") then return end

			if last_reloaded[path] and last_reloaded[path] > os.clock() then return end

			last_reloaded[path] = os.clock() + 0.2
			on_reload(path)
		end,
		true
	)
end

function hotreload.Stop()
	if hotreload.stop_watch then
		hotreload.stop_watch()
		hotreload.stop_watch = nil
	end
end

return hotreload
