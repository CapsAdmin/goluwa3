local gine = import("goluwa/gmod/gine.lua")
local vfs = import("goluwa/vfs.lua")
local prototype = import("goluwa/prototype.lua")
local repl = import("goluwa/repl.lua")
local timer = import("goluwa/timer.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local env = {}
env._R = {}
env._G = env
setmetatable(env, {__index = _G})
env.gine = gine
env.repl = repl
env.prototype = prototype
env.timer = timer
env.Vec2 = Vec2
env.Vec3 = Vec3
env.Matrix44 = Matrix44
env.Ang3 = Ang3
gine.env = env
local data = import("goluwa/gmod/" .. (CLIENT and "cl_" or SERVER and "sv_") .. "exported.lua")

do -- copy standard libraries
	local function add_lib_copy(name)
		local lib = {}

		for k, v in pairs(_G[name]) do
			lib[k] = v
		end

		env[name] = lib
	end

	add_lib_copy("string")
	add_lib_copy("math")
	add_lib_copy("table")
	add_lib_copy("coroutine")
	add_lib_copy("debug")
	add_lib_copy("bit")
	add_lib_copy("io")
	add_lib_copy("os")
	add_lib_copy("jit")
	env.table.insert = function(t, ...)
		table.insert(t, ...)
		return #t
	end
	env.debug.getregistry = function()
		return env._R
	end
	--env.debug.getinfo = function(...) local t = debug.getinfo(...) if t then t.short_src = t.source end return t end
	env.package = package

	for k in pairs(_OLD_G) do
		if type(_G[k]) == "function" then env[k] = _G[k] end
	end

	env.require = require("goluwa.require")
	env.module = require("goluwa.require").module
end

do -- enums
	env.gine_enums = data.enums

	for enum_name, value in pairs(data.enums) do
		env[enum_name] = env[enum_name] or value
	end
end

local override_detection_tracked = setmetatable({}, {__mode = "k"})

local function enable_override_detection(b)
	local function assign_with_newindex(target, newindex, key, value)
		if type(newindex) == "function" then return newindex(target, key, value) end

		if type(newindex) == "table" then
			newindex[key] = value
			return value
		end

		rawset(target, key, value)
		return value
	end

	local tracked = override_detection_tracked

	local function track_exported_functions(target, exported, format_name)
		if not b then
			local state = tracked[target]

			if not state then return end

			for key, value in pairs(state.backup) do
				if rawget(target, key) == nil then rawset(target, key, value) end
			end

			setmetatable(target, state.metatable)
			tracked[target] = nil
			return
		end

		local backup = {}

		for key in pairs(exported) do
			local value = rawget(target, key)

			if value ~= nil then
				backup[key] = value
				rawset(target, key, nil)
			end
		end

		local original_metatable = getmetatable(target)
		local metatable = {}

		if original_metatable then
			for key, value in pairs(original_metatable) do
				metatable[key] = value
			end
		end

		local original_index = metatable.__index
		local original_newindex = metatable.__newindex
		metatable.__index = function(self, key)
			local value = backup[key]

			if value ~= nil then return value end

			if type(original_index) == "function" then return original_index(self, key) end

			if type(original_index) == "table" then return original_index[key] end
		end
		metatable.__newindex = function(self, key, value)
			local export_type = exported[key]

			if export_type == "L" then
				wlog("adding function that will be overridden later by glua %s", format_name(key), 2)
			elseif export_type == nil and type(value) == "function" then
				wlog("adding function that doesn't exist in glua: %s", format_name(key), 2)
			end

			if export_type then backup[key] = nil end

			return assign_with_newindex(self, original_newindex, key, value)
		end
		tracked[target] = {
			backup = backup,
			metatable = original_metatable,
		}
		setmetatable(target, metatable)
	end

	for _, meta in pairs(env._R) do
		if meta.MetaName then
			if b then
				setmetatable(
					meta,
					{
						__newindex = function(s, k, v)
							if meta.__lua_functions and meta.__lua_functions[k] then
								wlog(
									"adding function that will be overridden later by glua %s.%s",
									meta.MetaName,
									k,
									2
								)
							end

							rawset(s, k, v)
						end,
					}
				)
			else
				setmetatable(meta, nil)
			end
		end
	end

	track_exported_functions(env, data.globals, function(key)
		return key
	end)

	for lib_name, functions in pairs(data.functions) do
		if env[lib_name] then
			track_exported_functions(env[lib_name], functions, function(key)
				return lib_name .. "." .. key
			end)
		end
	end
end

local ensure_meta_table

do
	env.table.Copy = env.table.Copy or table.copy
	env.table.Merge = env.table.Merge or table.merge

	function ensure_meta_table(name)
		local meta = env._R[name]

		if meta then return meta end

		meta = {
			MetaName = name,
		}
		meta.__index = meta

		function meta:IsValid()
			if not self or self.__removed then return false end

			return self.__obj and self.__obj.IsValid and self.__obj:IsValid() or false
		end

		function meta:Remove()
			self.__removed = true

			if self.__obj then
				timer.Delay(0, function()
					prototype.SafeRemove(self.__obj)
				end)
			end
		end

		env._R[name] = meta
		return meta
	end

	env.RegisterMetaTable = env.RegisterMetaTable or
		function(name, meta)
			if type(name) ~= "string" or type(meta) ~= "table" then return meta end

			meta.MetaName = meta.MetaName or name
			meta.__index = meta.__index or meta
			env._R[name] = meta
			return meta
		end
	env.Model = env.Model or function(path)
		return path
	end
	env.Sound = env.Sound or function(path)
		return path
	end

	local function coerce_accessor_value(value, force)
		if force == env.FORCE_BOOL then return not not value end

		if force == env.FORCE_NUMBER then return tonumber(value) or 0 end

		if force == env.FORCE_STRING then return tostring(value) end

		return value
	end

	env.AccessorFunc = env.AccessorFunc or
		function(tbl, key, name, force)
			local getter_name = (force == env.FORCE_BOOL and "Is" or "Get") .. name
			tbl["Set" .. name] = function(self, value)
				value = coerce_accessor_value(value, force)
				self[key] = value
				return value
			end
			tbl[getter_name] = function(self, default)
				local value = self[key]

				if value == nil then return default end

				return value
			end

			if force == env.FORCE_BOOL then tbl["Get" .. name] = tbl[getter_name] end
		end
	env.AccessorFuncDT = env.AccessorFuncDT or env.AccessorFunc
end

do
	local stored = {}
	env.baseclass = env.baseclass or {}
	env.baseclass.Get = env.baseclass.Get or
		function(name)
			if env.ENT then env.ENT.Base = name end

			if env.SWEP then env.SWEP.Base = name end

			stored[name] = stored[name] or {}
			return stored[name]
		end
	env.baseclass.Set = env.baseclass.Set or
		function(name, tab)
			stored[name] = stored[name] or {}
			env.table.Merge(stored[name], tab)
			stored[name].ThisClass = name
			return stored[name]
		end
	env.baseclass.GetTable = env.baseclass.GetTable or function()
		return stored
	end
end

-- global functions
for func_name, type in pairs(data.globals) do
	if type == "C" then
		env[func_name] = env[func_name] or
			function(...)
				logf(("glua NYI: %s(%s)\n"):format(func_name, list.concat(tostring_args(...), ",")))
			end
	end
end

-- metatables
for meta_name, functions in pairs(data.meta) do
	functions.__tostring = nil
	functions.__newindex = nil

	if not env._R[meta_name] then
		local META = ensure_meta_table(meta_name)

		if functions.IsValid then
			function META:IsValid()
				if not self or self.__removed then return false end

				return self.__obj and self.__obj:IsValid()
			end
		end

		if functions.Remove then
			function META:Remove()
				self.__removed = true

				timer.Delay(0, function()
					prototype.SafeRemove(self.__obj)
				end)
			end
		end
	end

	for func_name, type in pairs(functions) do
		if type == "C" then
			env._R[meta_name][func_name] = env._R[meta_name][func_name] or
				function(...)
					wlog("NYI: %s:%s(%s)", meta_name, func_name, list.concat(tostring_args(...), ","), 2)
				end
		else
			env._R[meta_name].__lua_functions = env._R[meta_name].__lua_functions or {}
			env._R[meta_name].__lua_functions[func_name] = true
		end
	end

	gine.objects[meta_name] = gine.objects[meta_name] or {}
end

-- libraries
for lib_name, functions in pairs(data.functions) do
	env[lib_name] = env[lib_name] or {}

	for func_name, type in pairs(functions) do
		if type == "C" then
			env[lib_name][func_name] = env[lib_name][func_name] or
				function(...)
					wlog(
						(
							"NYI: %s.%s(%s)"
						):format(lib_name, func_name, list.concat(tostring_args(...), ",")),
						2
					)
				end
		end
	end
end

enable_override_detection(true)
gine.hooks = gine.hooks or {}
env.hook = env.hook or {}
env.gamemode = env.gamemode or {}

do
	local function run_hook(name, gm, ...)
		local callbacks = gine.hooks[name]

		if callbacks then
			for _, callback in pairs(callbacks) do
				local a, b, c, d, e = callback(...)

				if a ~= nil then return a, b, c, d, e end
			end
		end

		gm = gm or env.GAMEMODE or gine.current_gamemode

		if gm and gm[name] then return gm[name](gm, ...) end
	end

	env.hook.Add = env.hook.Add or
		function(name, id, callback)
			gine.hooks[name] = gine.hooks[name] or {}
			gine.hooks[name][id] = callback
			return callback
		end
	env.hook.Remove = env.hook.Remove or
		function(name, id)
			if gine.hooks[name] then gine.hooks[name][id] = nil end
		end
	env.hook.Run = env.hook.Run or function(name, ...)
		return run_hook(name, nil, ...)
	end
	env.hook.Call = env.hook.Call or function(name, gm, ...)
		return run_hook(name, gm, ...)
	end
	env.gamemode.Register = env.gamemode.Register or
		function(gm, name, base)
			local base_gm = base and gine.gamemodes and gine.gamemodes[base]

			if base_gm then
				local mt = getmetatable(gm)

				if mt then
					mt.__index = mt.__index or base_gm
				else
					setmetatable(gm, {__index = base_gm})
				end

				gm.BaseClass = gm.BaseClass or base_gm
				gm.Base = gm.Base or base
			end

			gm.FolderName = gm.FolderName or name
			gine.gamemodes = gine.gamemodes or {}
			gine.gamemodes[name] = gm
			return gm
		end
	env.gamemode.Call = env.gamemode.Call or
		function(name, ...)
			return run_hook(name, env.GAMEMODE or gine.current_gamemode, ...)
		end
end

if gine.debug then
	for _, meta in pairs(env._R) do
		setmetatable(
			meta,
			{
				__newindex = function(s, k, v)
					if not k:starts_with("__") then
						wlog("adding meta function that doesn't exist in glua: %s", k, 2)
					end

					rawset(s, k, v)
				end,
			}
		)
	end

	setmetatable(
		env,
		{
			__index = _G,
			__newindex = function(s, k, v)
				wlog("adding function that doesn't exist in glua: %s", k, 2)
				rawset(s, k, v)
			end,
		}
	)
end

function gine.GetMetaTable(name)
	return gine.env._R[name] or ensure_meta_table(name)
end

vfs.RunFile("goluwa/gmod/libraries/*", gine)
vfs.RunFile(
	"goluwa/gmod/libraries/" .. (
			CLIENT and
			"client" or
			SERVER and
			"server"
		) .. "/*",
	gine
)

do
	for _, name in ipairs{
		"AccessorFunc",
		"AccessorFuncDT",
		"baseclass",
		"chat",
		"derma",
		"draw",
		"gmod",
		"gamemode",
		"gui",
		"hook",
		"include",
		"input",
		"language",
		"matproxy",
		"net",
		"surface",
		"util",
		"vgui",
	} do
		if env[name] ~= nil then _G[name] = env[name] end
	end
end

_G.repl = _G.repl or repl

for meta_name, functions in pairs(data.meta) do
	local meta = gine.GetMetaTable(meta_name)

	if functions["Is" .. meta_name] == "C" then
		meta["Is" .. meta_name] = function()
			return true
		end
	end

	for meta_name2 in pairs(data.meta) do
		if meta_name2 ~= meta_name then
			meta["Is" .. meta_name2] = function()
				return false
			end
		end
	end
end

if gine.debug then
	setmetatable(env)

	for _, meta in pairs(env._R) do
		setmetatable(meta)
	end
end

setmetatable(env, {__index = _G})
enable_override_detection(false)
