-- todo
_G.CLIENT = true
_G.SERVER = false
local gine = library()
gine.debug = true
_G.gine = gine
import.loaded["goluwa/gmod/gine.lua"] = gine
import("goluwa/gmod/preprocess.lua")
import("goluwa/gmod/commands.lua")
import("goluwa/gmod/filewatcher.lua")
local event = import("goluwa/event.lua")
local steam = import("goluwa/steam.lua")
local system = import("goluwa/system.lua")
local timer = import("goluwa/timer.lua")
local vfs = import("goluwa/vfs.lua")
local R = vfs.GetAbsolutePath
local prototype = import("goluwa/prototype.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local commands = import("goluwa/commands.lua")
local utility = import("goluwa/utility.lua")
local pvars = import("goluwa/pvars.lua")
local render = import("goluwa/render/render.lua")
_G.prototype = prototype
_G.Vec2 = Vec2
_G.Vec3 = Vec3
_G.Matrix44 = Matrix44
_G.Ang3 = Ang3

function gine.SetFunctionEnvironment(func)
	if not gine.env then return func end

	setfenv(func, gine.env)
	return func
end

function gine.AddEvent(what, callback)
	event.AddListener(
		what,
		"gine",
		function(...)
			if gine.env then return callback(...) end
		end,
		{on_error = system.OnError}
	)
end

local function run_client_graphics_bootstrap()
	if gine.client_graphics_bootstrap_loaded then return end

	gine.client_graphics_bootstrap_loaded = true
	vfs.RunFile("lua/postprocess/*")
	vfs.RunFile("lua/vgui/*")
	vfs.RunFile("lua/matproxy/*")
	vfs.RunFile("lua/skins/*")
end

local function ensure_client_graphics_bootstrap()
	if gine.client_graphics_bootstrap_loaded then return end

	if render.IsInitialized() then
		run_client_graphics_bootstrap()
		return
	end

	event.AddListener("RendererReady", "gine_client_graphics_bootstrap", function()
		run_client_graphics_bootstrap()
		return event.destroy_tag
	end)
end

gine.objects = gine.objects or {}
gine.objectsi = gine.objectsi or {}

function gine.WrapObject(obj, meta)
	gine.objects[meta] = gine.objects[meta] or {}
	gine.objectsi[meta] = gine.objectsi[meta] or {}

	if not gine.objects[meta][obj] then
		local tbl = table.copy(gine.EnsureMetaTable(meta))
		tbl.Type = meta
		local __index_func
		local __index_tbl

		if type(tbl.__index) == "function" then
			__index_func = tbl.__index
		else
			__index_tbl = tbl.__index
		end

		obj.gine_vars = obj.gine_vars or {}

		function tbl:__index(key)
			if key == "__obj" then return obj end

			if key == "__vars" then return obj.gine_vars end

			if __index_func then
				return __index_func(self, key)
			elseif __index_tbl then
				return __index_tbl[key]
			end
		end

		tbl.__gc = nil
		gine.objects[meta][obj] = setmetatable({}, tbl)

		if obj.CallOnRemove then
			obj:CallOnRemove(function()
				if gine.objects[meta] and gine.objects[meta][obj] then
					local obj = gine.objects[meta][obj]

					for i, v in ipairs(gine.objectsi[meta]) do
						if v == obj then
							list.remove(gine.objectsi[meta], i)

							break
						end
					end

					timer.Delay(function()
						prototype.MakeNULL(obj)
					end)

					gine.objects[meta][obj] = nil
				end
			end)
		end

		list.insert(gine.objectsi[meta], {external = gine.objects[meta][obj], internal = obj})
	end

	return gine.objects[meta][obj]
end

function gine.GetSet(META, name, def)
	if type(def) ~= "function" then
		local val = def
		def = function()
			return val
		end
	end

	META["Set" .. name] = function(self, val)
		self.__obj.gine_vars[name] = val
	end
	META["Get" .. name] = function(self)
		if def and self.__obj.gine_vars[name] == nil then return def() end

		return self.__obj.gine_vars[name]
	end
end

function gine.GetReverseEnums(pattern)
	local out = {}

	for k, v in pairs(gine.env.gine_enums) do
		local what = k:match(pattern)

		if what then out[v] = what:lower() end
	end

	return out
end

function gine.GetEnums(pattern)
	local out = {}

	for k, v in pairs(gine.env.gine_enums) do
		local what = k:match(pattern)

		if what then out[what:lower()] = v end
	end

	return out
end

gine.glua_paths = gine.glua_paths or {}
gine.package_loader_dirs = gine.package_loader_dirs or {}

do
	local glua_source_repo = "https://github.com/Facepunch/garrysmod.git"
	local glua_source_checkout_path = "goluwa/gmod/src/garrysmod/"

	local function add_unique_path(tbl, path)
		if type(path) ~= "string" or path == "" then return end

		for _, existing in ipairs(tbl) do
			if existing:lower() == path:lower() then return end
		end

		list.insert(tbl, path)
	end

	local function add_package_loader_dir(dir)
		if type(dir) ~= "string" or dir == "" then return end

		if not vfs.IsDirectory(dir) then return end

		local key = dir:lower()

		if gine.package_loader_dirs[key] then return end

		gine.package_loader_dirs[key] = true

		utility.AddPackageLoader(
			function(path)
				return vfs.LoadFile(dir .. "/" .. path .. ".lua")
			end,
			gine.package_loaders
		)
	end

	local function shell_quote(str)
		return "'" .. str:gsub("'", "'\"'\"'") .. "'"
	end

	local function command_exists(name)
		if type(system.OSCommandExists) == "function" then
			return system.OSCommandExists(name)
		end

		local probe = WINDOWS and
			(
				"where " .. name .. " >nul 2>nul"
			)
			or
			(
				"command -v " .. name .. " >/dev/null 2>&1"
			)
		local ok = os.execute(probe)

		if type(ok) == "number" then return ok == 0 end

		if type(ok) == "boolean" then return ok end

		return false
	end

	local function get_glua_source_checkout_root()
		local gmod_root = R("goluwa/gmod/", true)

		if not gmod_root then return nil end

		return gmod_root .. glua_source_checkout_path:match("^goluwa/gmod/(.+)$")
	end

	local function get_glua_source_overlay_root()
		local checkout_root = get_glua_source_checkout_root()

		if not checkout_root then return nil end

		local overlay_root = checkout_root .. "garrysmod/"

		if vfs.IsDirectory(overlay_root) then return overlay_root end

		return nil
	end

	local function get_glua_redirect_root()
		if gine.glua_source_dir and vfs.IsDirectory(gine.glua_source_dir) then
			return gine.glua_source_dir
		end

		local redirect = e.ROOT_FOLDER .. "garrysmod/garrysmod/"

		if vfs.IsDirectory(redirect) then return redirect end

		return nil
	end

	function gine.EnsureGLuaSourceClone()
		local checkout_root = get_glua_source_checkout_root()

		if not checkout_root then return nil, "failed to resolve goluwa/gmod/" end

		local overlay_root = checkout_root .. "garrysmod/"

		if vfs.IsDirectory(overlay_root) then return overlay_root end

		if not command_exists("git") then
			return nil, "git is not available in PATH"
		end

		local src_root = checkout_root:match("(.+/)garrysmod/$")

		if src_root and not vfs.IsDirectory(src_root) then
			local ok, err = os.execute("mkdir -p " .. shell_quote(src_root))

			if ok == nil and err then return nil, err end
		end

		local ok, err = os.execute("git clone --depth 1 " .. glua_source_repo .. " " .. shell_quote(checkout_root))

		if ok == nil and err then return nil, err end

		if vfs.IsDirectory(overlay_root) then return overlay_root end

		return nil,
		"git clone finished but garrysmod/ was not found in " .. checkout_root
	end

	function gine.GetGLuaSourceDir()
		return get_glua_source_overlay_root()
	end

	function gine.RedirectGLuaPath(path)
		if type(path) ~= "string" then return path end

		local lower_path = path:lower()

		if
			not lower_path:find("garrysmod/garrysmod/lua/", nil, true) and
			not lower_path:find("garrysmod/garrysmod/gamemodes/", nil, true)
		then
			return path
		end

		local redirect_root = get_glua_redirect_root()

		if not redirect_root then return path end

		local relative_path = path:match("^.-garrysmod/garrysmod/(.+)$")

		if not relative_path then return path end

		local new_path = redirect_root .. relative_path

		if new_path:lower() ~= lower_path and vfs.IsFile(new_path) then
			return new_path
		end

		return path
	end

	function gine.AddGLuaPath(path)
		add_unique_path(gine.glua_paths, path)
	end

	function gine.AddPackageLoaderDir(dir)
		add_package_loader_dir(dir)
	end

	function gine.MountGLuaSourceOverlay()
		local overlay_root, err = gine.EnsureGLuaSourceClone()

		if not overlay_root then
			wlog("failed to prepare Garry's Mod source overlay: %s", err or "unknown error")
			return nil, err
		end

		gine.glua_source_dir = overlay_root
		vfs.Mount(overlay_root)
		gine.AddGLuaPath(overlay_root)
		gine.AddPackageLoaderDir(overlay_root .. "lua/includes/modules")
		return overlay_root
	end
end

do
	local resource_path_hints = {
		material = {root = "materials/", extensions = {".vmt"}},
		texture = {
			root = "materials/",
			extensions = {".vtf", ".png", ".jpg", ".jpeg", ".dds", ".gif"},
		},
		sound = {root = "sound/"},
	}

	local function is_absolute_path(path)
		return path:starts_with("/") or path:starts_with("os:") or path:sub(2, 2) == ":"
	end

	local function add_candidate(candidates, seen, candidate)
		if type(candidate) ~= "string" or candidate == "" then return end

		candidate = candidate:gsub("\\", "/")
		local key = candidate:lower()

		if seen[key] then return end

		seen[key] = true
		list.insert(candidates, candidate)
	end

	local function strip_resource_root(path, root)
		path = path:gsub("\\", "/")
		local lower_path = path:lower()
		local lower_root = root:lower()
		local start = lower_path:find(lower_root, 1, true)

		if start then path = path:sub(start) end

		if path:lower():starts_with(lower_root) then return path:sub(#root + 1) end

		return path
	end

	local function apply_resource_root(path, root)
		if is_absolute_path(path) or path:lower():starts_with(root:lower()) then
			return path
		end

		return root .. path
	end

	function gine.LogPathResolveFailure(path, hint, failed_paths)
		if type(path) ~= "string" or path == "" then return end

		local parts = {}

		for _, failed_path in ipairs(failed_paths or {}) do
			list.insert(parts, failed_path)
		end

		if #parts == 0 then
			wlog("gine failed to resolve %s path %q", hint or "resource", path)
			return
		end

		wlog(
			"gine failed to resolve %s path %q; tried: %s",
			hint or "resource",
			path,
			table.concat(parts, ", ")
		)
	end

	function gine.GetPathCandidates(path, hint)
		if type(path) ~= "string" or path == "" then return {} end

		path = path:gsub("\\", "/")
		hint = hint and hint:lower() or nil
		local candidates = {}
		local seen = {}
		local info = hint and resource_path_hints[hint] or nil

		if not info then
			add_candidate(candidates, seen, path)
		else
			local logical_path = strip_resource_root(path, info.root)
			local lower_path = logical_path:lower()
			local has_extension = logical_path:find(".+%.[^/]+$")

			if hint == "material" then
				if has_extension then
					add_candidate(candidates, seen, apply_resource_root(logical_path, info.root))
				else
					add_candidate(candidates, seen, apply_resource_root(logical_path .. ".vmt", info.root))
					add_candidate(candidates, seen, apply_resource_root(logical_path, info.root))
				end
			elseif hint == "texture" then
				local has_known_extension = false

				for _, ext in ipairs(info.extensions) do
					if lower_path:ends_with(ext) then
						has_known_extension = true

						break
					end
				end

				if has_known_extension then
					add_candidate(candidates, seen, apply_resource_root(logical_path, info.root))

					if lower_path:ends_with(".vtf") then
						add_candidate(candidates, seen, apply_resource_root(logical_path:sub(1, -5), info.root))
					end
				else
					if not has_extension then
						for _, ext in ipairs(info.extensions) do
							add_candidate(candidates, seen, apply_resource_root(logical_path .. ext, info.root))
						end
					end

					add_candidate(candidates, seen, apply_resource_root(logical_path, info.root))
				end
			elseif hint == "sound" then
				add_candidate(candidates, seen, apply_resource_root(logical_path, info.root))
			else
				add_candidate(candidates, seen, path)
			end
		end

		return candidates
	end

	function gine.ResolvePath(path, hint)
		if type(path) ~= "string" or path == "" then return nil end

		local candidates = gine.GetPathCandidates(path, hint)

		for _, candidate in ipairs(candidates) do
			local resolved_path = vfs.FindMixedCasePath(candidate)

			if resolved_path then return resolved_path end
		end

		gine.LogPathResolveFailure(path, hint, candidates)
		return nil
	end
end

function gine.IsWrapperPath(path)
	local lower_path = path:lower()

	if
		lower_path:find("/goluwa/gmod/src/garrysmod/", nil, true) or
		lower_path:find("goluwa/gmod/src/garrysmod/", nil, true)
	then
		return false
	end

	return lower_path:find("/goluwa/gmod/", nil, true) or
		lower_path:find("goluwa/gmod/", nil, true)
end

function gine.IsGLuaPath(path, gmod_dir_only)
	if not path then return false end

	local lower_path = path:lower()

	if gine.IsWrapperPath(path) then return true end

	if
		lower_path:find("garrysmod/garrysmod/", nil, true) or
		lower_path:find("%.gma") or
		lower_path:starts_with("lua/") or
		lower_path:starts_with("gamemodes/")
	then
		return true
	end

	if not gmod_dir_only then
		for i, v in ipairs(gine.glua_paths) do
			if lower_path:starts_with(v:lower()) then return true end
		end
	end

	return false
end

gine.addons = gine.addons or {}
gine.package_loaders = {}
pvars.Setup("gine_local_addons_only", false)

function gine.Initialize(gamemode, skip_addons)
	gamemode = gamemode or "sandbox"

	event.AddListener("PreLoadFile", "glua", function(path)
		if
			gine.IsGLuaPath(path, true) and
			(
				path:lower():find("garrysmod/garrysmod/lua/", nil, true) or
				path:lower():find("garrysmod/garrysmod/gamemodes/")
			)
		then
			local new_path = gine.RedirectGLuaPath(path)

			if new_path ~= path then return new_path end

			return
		end

		return event.destroy_tag
	end)

	event.AddListener("PreLoadString", "glua_preprocess", function(code, path)
		if not gine.IsGLuaPath(path) then return end

		if gine.IsWrapperPath(path) then return code end

		local ok, msg = pcall(gine.PreprocessLua, code)

		if not ok then
			logn(msg)
			return
		end

		code = msg

		if not loadstring(code) then vfs.Write("glua_preprocess_error.lua", code) end

		if not gine.init then
			return "commands.RunString('gluacheck " .. path .. "')"
		end

		return code
	end)

	event.AddListener("PostLoadString", "glua_function_env", function(func, path)
		if gine.IsGLuaPath(path) then return gine.SetFunctionEnvironment(func) end

		return func
	end)

	if not gine.init then
		gine.MountGLuaSourceOverlay()
		steam.MountSourceGame("gmod", skip_addons)
		pvars.Setup("sv_allowcslua", 1)
		-- figure out the base gmod folder
		gine.dir = R("garrysmod_dir.vpk"):match("(.+/)")
		gine.AddGLuaPath(gine.dir)
		import("goluwa/gmod/material.lua")
		-- setup engine functions
		import("goluwa/gmod/environment.lua")
		gine.AddPackageLoaderDir(gine.dir .. "lua/includes/modules")
		-- include and init files in the right order
		gine.init = true

		if not skip_addons then
			local function mount(full_path)
				if full_path:match(".+/(.+)"):starts_with("__") then return end

				list.insert(gine.addons, full_path)
				vfs.Mount(full_path)
				local dir = R(full_path .. "/lua/includes/modules/")

				if dir then
					dir = "os:" .. dir

					utility.AddPackageLoader(
						function(path)
							return vfs.LoadFile(dir .. "/" .. path .. ".lua")
						end,
						gine.package_loaders
					)
				end

				list.insert(gine.glua_paths, full_path)

				if vfs.IsDirectory(full_path .. "addons") then
					for dir in vfs.Iterate(full_path .. "addons/", true) do
						if vfs.IsDirectory(dir) then mount(dir .. "/") end
					end
				end
			end

			for _, info in ipairs(vfs.disabled_addons) do
				if info.gmod_addon then mount(info.path) end
			end

			if not pvars.Get("gine_local_addons_only") then
				for dir in vfs.Iterate(gine.dir .. "addons/", true) do
					dir = R(dir .. "/lua/includes/modules/")

					if dir then
						dir = "os:" .. dir

						utility.AddPackageLoader(
							function(path)
								return vfs.LoadFile(dir .. "/" .. path .. ".lua")
							end,
							gine.package_loaders
						)
					end
				end
			end
		end

		vfs.RunFile("lua/includes/init.lua")

		if CLIENT then
			--runfile("lua/includes/init_menu.lua")
			gine.env.require("notification")
			vfs.RunFile("lua/derma/init.lua") -- the gui
		end

		gine.LoadGamemode("base")

		if gamemode ~= "base" then gine.LoadGamemode(gamemode) end

		-- autorun lua files
		vfs.RunFile("lua/autorun/*")

		if CLIENT then vfs.RunFile("lua/autorun/client/*") end

		if SERVER then vfs.RunFile("lua/autorun/server/*") end

		if CLIENT then ensure_client_graphics_bootstrap() end

		--gine.env.DCollapsibleCategory.LoadCookies = nil -- DUCT TAPE FIX
		for name in pairs(gine.gamemodes) do
			local entities_dir = R("gamemodes/" .. name .. "/entities/", true)

			if entities_dir then vfs.Mount(entities_dir, "lua/") end
		end

		if CLIENT then
			for path in vfs.Iterate("resource/localization/en/", true) do
				for _, line in ipairs(vfs.Read(path):split("\n")) do
					local key, val = line:match("(.-)=(.+)")

					if key and val then
						gine.translation[key] = val:trim()
						gine.translation2["#" .. key] = gine.translation[key]
					end
				end
			end

			gine.LoadFonts()
		end
	end
end

function gine.Run(skip_addons)
	if not skip_addons then
		for _, path in ipairs(gine.addons) do
			vfs.RunFile(path .. "lua/includes/extensions/*")
		end

		if not pvars.Get("gine_local_addons_only") then
			for dir in vfs.Iterate(gine.dir .. "addons/", true, true) do
				local dir = gine.dir .. "addons/" .. dir
				vfs.RunFile(dir .. "/lua/includes/extensions/*")
			end
		end

		for _, path in ipairs(gine.addons) do
			vfs.RunFile(path .. "lua/autorun/*")

			if CLIENT then vfs.RunFile(path .. "lua/autorun/client/*") end

			if SERVER then vfs.RunFile(path .. "lua/autorun/server/*") end
		end

		if not pvars.Get("gine_local_addons_only") then
			for dir in vfs.Iterate(gine.dir .. "addons/", true, true) do
				vfs.RunFile(dir .. "/lua/autorun/*")

				if CLIENT then vfs.RunFile(dir .. "/lua/autorun/client/*") end

				if SERVER then vfs.RunFile(dir .. "/lua/autorun/server/*") end
			end
		end
	end

	gine.LoadEntities(
		"lua/entities",
		"ENT",
		gine.env.scripted_ents.Register,
		function()
			return {}
		end
	)

	gine.LoadEntities(
		"lua/weapons",
		"SWEP",
		gine.env.weapons.Register,
		function()
			return {Primary = {}, Secondary = {}, AnimExtension = {}}
		end
	)

	if CLIENT then
		gine.LoadEntities("lua/effects", "EFFECT", gine.env.effects.Register, function()
			return {}
		end)
	end

	gine.env.gamemode.Call("CreateTeams")
	gine.env.gamemode.Call("PreGamemodeLoaded")
	gine.env.gamemode.Call("OnGamemodeLoaded")
	gine.env.gamemode.Call("PostGamemodeLoaded")
	gine.env.gamemode.Call("Initialize")
	gine.env.gamemode.Call("InitPostEntity")

	if CLIENT and CAPS then
		--		require("opengl").Disable("GL_SCISSOR_TEST")
		if gine.env.notagain then
			gine.env.LocalPlayer():SetNWBool("rpg", true)
			gine.env.LocalPlayer():SetHealth(250)
			gine.env.LocalPlayer():SetMaxHealth(250)
			gine.env.LocalPlayer():SetNWFloat("jattributes_max_stamina", 85)
			gine.env.LocalPlayer():SetNWFloat("jattributes_stamina", 85)
			gine.env.LocalPlayer():SetNWFloat("jattributes_max_mana", 185)
			gine.env.LocalPlayer():SetNWFloat("jattributes_mana", 185)
			gine.env.avatar.SetPlayer(
				gine.env.LocalPlayer(),
				"https://cdn.discordapp.com/attachments/273575417401573377/290168526709194752/ZKxp1lm.png",
				192,
				200,
				2
			)
		end
	end
end

commands.Add("ginit=string[sandbox],boolean", function(gamemode, skip_addons)
	utility.PushTimeWarning()
	gine.Initialize(gamemode, skip_addons)
	utility.PopTimeWarning("gine.Initialize", 0)
	utility.PushTimeWarning()
	gine.Run(skip_addons)
	utility.PopTimeWarning("gine.Run", 0)
end)

event.AddListener("KeyInput", function(key, press)
	if key == "q" and press then commands.RunString("ginit") end
end)

commands.Add("glua=arg_line", function(code)
	if not gine.env then gine.Initialize() end

	local func = assert(loadstring(code))
	setfenv(func, gine.env)
	print(func())
end)

if CAPS then
	timer.Delay(0, function() --commands.RunString("ginit base,1")
	end)
end

return gine
