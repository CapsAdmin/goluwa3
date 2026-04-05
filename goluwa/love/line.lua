local pvars = import("goluwa/pvars.lua")
local module_require = import("goluwa/require.lua")
local event = import("goluwa/event.lua")
local vfs = import("goluwa/vfs.lua")
local commands = import("goluwa/commands.lua")
local resource = import("goluwa/resource.lua")
local R = vfs.GetAbsolutePath
local line = library()
line.speed = 1
line.love_envs = line.love_envs or table.weak()
pvars.Setup("line_enable_audio", true)
pvars.Setup("line_version", "0.10.1")

local function apply_love_version(love, version)
	version = tostring(version or pvars.Get("line_version") or "0.10.1")
	local major, minor, revision = version:match("^(%d+)%.(%d+)%.?(%d*)$")

	if not major then major, minor, revision = "0", "10", "1" end

	revision = revision ~= "" and revision or "0"
	love._version_major = tonumber(major) or 0
	love._version_minor = tonumber(minor) or 0
	love._version_revision = tonumber(revision) or 0
	love._version = string.format("%d.%d.%d", love._version_major, love._version_minor, love._version_revision)
end

do
	local function base_typeOf(self, str)
		return str == (self.__line_type or self.name)
	end

	local function base_type(self)
		return self.__line_type or self.name
	end

	local created = table.weak()
	local registered = {}

	function line.TypeTemplate(name)
		local META = {}
		META.__line_type = name
		return META
	end

	function line.RegisterType(META)
		META.__index = META
		META.typeOf = base_typeOf
		META.type = base_type
		registered[META.__line_type] = META
		-- some löve scripts get it from here
		debug.getregistry()[META.__line_type] = META

		if created[META.__line_type] then
			for i, v in ipairs(created[META.__line_type]) do
				setmetatable(v, META)
			end
		end
	end

	function line.CreateObject(name)
		local META = registered[name]
		local self = setmetatable({}, META)
		created[META.__line_type] = created[META.__line_type] or {}
		list.insert(created[META.__line_type], self)
		return self
	end

	function line.Type(v)
		local t = type(v)

		if t == "table" and v.__line_type then return v.__line_type end

		return t
	end

	function line.GetCreatedObjects(name)
		return created[name] or {}
	end
end

function line.ErrorNotSupported(str, level)
	wlog("[line] " .. str)
end

function line.CreateLoveEnv(version)
	version = version or pvars.Get("line_version")
	local love = {}
	apply_love_version(love, version)
	love._line_env = {}
	love._modules = {}
	love.package_loaders = {}
	assert(loadfile("goluwa/love/libraries/arg.lua"))(love)
	love._modules.arg = true
	assert(loadfile("goluwa/love/libraries/event.lua"))(love)
	love._modules.event = true
	assert(loadfile("goluwa/love/libraries/graphics.lua"))(love)
	love._modules.graphics = true
	assert(loadfile("goluwa/love/libraries/joystick.lua"))(love)
	love._modules.joystick = true
	assert(loadfile("goluwa/love/libraries/love.lua"))(love)
	assert(loadfile("goluwa/love/libraries/mouse.lua"))(love)
	love._modules.mouse = true
	assert(loadfile("goluwa/love/libraries/physics.lua"))(love)
	love._modules.physics = true
	assert(loadfile("goluwa/love/libraries/system.lua"))(love)
	love._modules.system = true
	assert(loadfile("goluwa/love/libraries/timer.lua"))(love)
	love._modules.timer = true
	assert(loadfile("goluwa/love/libraries/audio.lua"))(love)
	love._modules.audio = true
	assert(loadfile("goluwa/love/libraries/filesystem.lua"))(love)
	love._modules.filesystem = true
	assert(loadfile("goluwa/love/libraries/data.lua"))(love)
	love._modules.data = true
	assert(loadfile("goluwa/love/libraries/image_data.lua"))(love)
	love._modules.image = true
	assert(loadfile("goluwa/love/libraries/keyboard.lua"))(love)
	love._modules.keyboard = true
	assert(loadfile("goluwa/love/libraries/math.lua"))(love)
	love._modules.math = true
	assert(loadfile("goluwa/love/libraries/particles.lua"))(love)
	love._modules.particles = true
	assert(loadfile("goluwa/love/libraries/sound.lua"))(love)
	love._modules.sound = true
	assert(loadfile("goluwa/love/libraries/thread.lua"))(love)
	love._modules.thread = true
	assert(loadfile("goluwa/love/libraries/window.lua"))(love)
	love._modules.window = true
	list.insert(line.love_envs, love)
	setmetatable(
		love,
		{
			__newindex = function(t, k, v)
				if type(v) == "function" then
					llog("love.%s = %s", k, v)
					event.Call("LoveNewIndex", t, k, v)
				end

				rawset(t, k, v)
			end,
		}
	)
	return love
end

do
	local current_love
	local on_error = function(msg)
		current_love._line_env.error_message = msg .. "\n" .. debug.traceback()
		logn(current_love._line_env.error_message)
	end

	function line.pcall(love, func, ...)
		if love._line_env.error_message then return end

		current_love = love
		local ret = {xpcall(func, on_error, ...)}

		if ret[1] then return select(2, unpack(ret)) end
	end
end

function line.CallEvent(what, a, b, c, d, e, f)
	for i, love in ipairs(line.love_envs) do
		if love[what] and not love._line_env.error_message then
			local a, b, c, d, e, f = line.pcall(love, love[what], a, b, c, d, e, f)

			if a then return a, b, c, d, e, f end
		end
	end
end

function line.FixPath(path)
	if path:starts_with("/") or path:starts_with("\\") then return path:sub(2) end

	return path
end

function line.SyncWindowGlobals(love, width, height)
	if not love or not love._line_env then return end

	local globals = love._line_env.globals

	if not globals then return end

	width = tonumber(width)
	height = tonumber(height)

	if not width or not height then return end

	globals.ScreenWidth = width
	globals.ScreenHeight = height
	globals.windowWidth = width
	globals.windowHeight = height
	globals.WINDOW_WIDTH = width
	globals.WINDOW_HEIGHT = height
end

function line.SyncAllWindowGlobals(width, height)
	for _, love in ipairs(line.love_envs) do
		line.SyncWindowGlobals(love, width, height)
	end
end

local function get_game_identity(folder)
	local identity = folder:gsub("[/\\]+$", ""):match("([^/\\]+)$") or "lovegame"
	identity = identity:gsub("^([%.]+)", "")
	identity = identity:gsub("%.([^%.]+)$", "")
	identity = identity:gsub("%.", "_")
	return #identity > 0 and identity or "lovegame"
end

function line.RunGame(folder, ...)
	local love = line.CreateLoveEnv()
	llog("mounting love game folder: ", R(folder .. "/"))
	assert(vfs.CreateDirectory("os:data/love/", true))
	module_require.AddSearcher(
		module_require.MakeLuaSearcher("?.lua;?/init.lua", module_require.LoadPath),
		love.package_loaders,
		1
	)
	vfs.AddModuleDirectory("lua/modules/", love.package_loaders)
	vfs.AddModuleDirectory("data/love/", love.package_loaders)
	vfs.Mount(assert(R(folder .. "/")))
	local os = {}

	for k, v in pairs(_G.os) do
		os[k] = v
	end

	function os.execute(str)
		print("os.execute: ", str)

		if str:find("__LOVE_BINARY__") then
			local path = vfs.FixPathSlashes(str:match(".+\"(.+%.love)\""))

			if vfs.IsFile(path) then line.RunGame(path) end

			return
		end

		os.execute(str)
	end

	local package_loaded = {}
	local env
	local game_globals = love._line_env.globals or {}
	love._line_env.globals = game_globals
	local vendored_luasocket_modules = {
		["ltn12"] = "goluwa/sockets/luasocket/ltn12.lua",
		["socket"] = "goluwa/sockets/luasocket/socket.lua",
		["socket.core"] = "goluwa/love/libraries/socket_core.lua",
		["socket.ftp"] = "goluwa/sockets/luasocket/ftp.lua",
		["socket.headers"] = "goluwa/sockets/luasocket/headers.lua",
		["socket.http"] = "goluwa/sockets/luasocket/http.lua",
		["socket.smtp"] = "goluwa/sockets/luasocket/smtp.lua",
		["socket.tp"] = "goluwa/sockets/luasocket/tp.lua",
		["socket.url"] = "goluwa/sockets/luasocket/url.lua",
		["utf8"] = "goluwa/utf8.lua",
	}
	love._line_env.filesystem_source = R(folder .. "/")

	local function prepare_module_function(func)
		if type(func) == "function" and debug.getinfo(func).what ~= "C" then
			setfenv(func, env)
		end

		return func
	end

	local function line_require(name)
		if name == "strict" then return true end

		if name == "love" then return love end

		if package_loaded[name] ~= nil then return package_loaded[name] end

		local function finalize_required_module(module_name, value)
			if module_name == "libraries.lily" and type(value) == "table" then
				love._line_env.lily = value

				if value.setUpdateMode then value.setUpdateMode("manual") end
			end

			return value
		end

		if vendored_luasocket_modules[name] then
			local func = assert(loadfile(vendored_luasocket_modules[name]))
			local result = prepare_module_function(func)()

			if result == nil then result = true end

			package_loaded[name] = result

			if name == "socket" or name == "socket.core" then env.socket = result end

			return finalize_required_module(name, result)
		end

		if name:starts_with("love.") and love[name:match(".+%.(.+)")] then
			local lib = love[name:match(".+%.(.+)")]
			package_loaded[name] = lib
			return finalize_required_module(name, lib)
		end

		local res, err, path = module_require.require_with_loaders(
			name,
			love.package_loaders,
			package_loaded,
			name,
			prepare_module_function
		)

		if res ~= nil then
			--llog("require: ", name, " (", path, ")")
			return finalize_required_module(name, res)
		end

		local ok, fallback = pcall(module_require, name)

		if ok then
			package_loaded[name] = fallback
			return finalize_required_module(name, fallback)
		end

		error(err, 2)
	end

	env = setmetatable(
		{
			os = os,
			love = love,
			require = line_require,
			type = function(v)
				local t = _G.type(v)

				if t == "table" and v.__line_type then return "userdata" end

				return t
			end,
			pcall = function(func, ...)
				if type(func) == "function" and debug.getinfo(func).what ~= "C" then
					setfenv(func, env)
				end

				return _G.pcall(func, ...)
			end,
			xpcall = function(func, err, ...)
				if type(func) == "function" and debug.getinfo(func).what ~= "C" then
					setfenv(func, env)
				end

				if type(err) == "function" and debug.getinfo(err).what ~= "C" then
					setfenv(err, env)
				end

				return _G.xpcall(func, err, ...)
			end,
			loadstring = function(...)
				local a, b = _G.loadstring(...)

				if type(a) == "function" then setfenv(a, env) end

				return a, b
			end,
		},
		{
			__index = function(_, k)
				local value = rawget(game_globals, k)

				if value ~= nil then return value end

				return _G[k]
			end,
			__newindex = function(_, k, v)
				rawset(game_globals, k, v)
			end,
		}
	)
	env._G = env
	env.arg = {...}
	env.utf8 = line_require("utf8")
	setmetatable(
		love,
		{
			__newindex = function(t, k, v)
				if type(v) == "function" then
					llog("love.%s = %s", k, v)
					event.Call("LoveNewIndex", t, k, v)
					setfenv(v, env)
				end

				rawset(t, k, v)
			end,
		}
	)
	love.filesystem.setIdentity(get_game_identity(folder))

	do -- config
		line.config = {
			screen = {},
			window = {},
			modules = {},
			identity = false,
			height = 600,
			width = 800,
			title = "LINE no title",
			author = "who knows",
		}

		if vfs.IsFile("conf.lua") then
			local func = assert(vfs.LoadFile("conf.lua"))
			setfenv(func, env)
			func()
		end

		love.conf(line.config)
		apply_love_version(love, line.config.version)
	end

	love.filesystem.setIdentity(line.config.identity or love.filesystem.getIdentity())

	--check if line.config.screen exists
	if not line.config.screen then line.config.screen = {} end

	local w = line.config.screen.width or line.config.window.width or 800
	local h = line.config.screen.height or line.config.window.height or 600

	if
		(
			w == nil or
			w <= 1 or
			h == nil or
			h <= 1
		)
		and
		line.config.window and
		line.config.window.fullscreen and
		line.config.window.fullscreentype == "desktop"
	then
		local modes = love.window.getFullscreenModes(line.config.window.display)
		local preferred = modes and modes[1] or nil
		w = preferred and preferred.width or 1280
		h = preferred and preferred.height or 720
	end

	local title = line.config.title or "Line"
	love.window.setMode(w, h)
	love.window.setTitle(title)
	local main = assert(vfs.LoadFile("main.lua"))
	setfenv(main, env)
	setfenv(love.line_update, env)
	setfenv(love.line_draw, env)
	line.pcall(love, main)
	line.pcall(
		love,
		love.load,
		{[-2] = "__LOVE_BINARY__", [-1] = "embedded boot.lua", [1] = folder .. "/"}
	)
	line.current_game = love
	love._line_env.love_game_update_draw_hack = false
	return love
end

function line.IsGameRunning()
	return line.current_game ~= nil
end

commands.Add("love_run=string,var_arg", function(name, ...)
	local found

	if vfs.IsDirectory("lovers/" .. name) then
		found = line.RunGame("lovers/" .. name, ...)
	elseif vfs.IsFile("lovers/" .. name .. ".love") then
		found = line.RunGame("lovers/" .. name .. ".love", ...)
	elseif name:find("github") then
		local url = name

		if name:starts_with("github/") then
			url = name:gsub("github/", "https://github.com/") .. "/archive/master.zip"
		else
			url = url .. "/archive/master.zip"
		end

		local args = {...}

		resource.Download(url):Then(function(full_path)
			full_path = full_path .. "/" .. name:match(".+/(.+)") .. "-master"
			logn("running downloaded löve game: ", full_path)
			line.RunGame(full_path, unpack(args))
		end)
	else
		for _, file_name in ipairs(vfs.Find("lovers/")) do
			if file_name:compare(name) and vfs.IsDirectory("lovers/" .. file_name) then
				found = line.RunGame("lovers/" .. file_name)

				break
			end
		end
	end

	if found then
		if menu then menu.Close() end
	else
		return false, "love game " .. name .. " does not exist"
	end
end)

event.AddListener("WindowDrop", "line", function(wnd, path)
	if vfs.IsDirectory(path) and vfs.IsFile(path .. "/main.lua") then
		line.RunGame(path)

		if menu then menu.Close() end
	end
end)

commands.Add("love=string", function(game)
	line.RunGame("/home/caps/projects/goluwa3/love_games/" .. game)
end)

return line
