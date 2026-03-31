local require = {}
local loaded_vfs

local function get_vfs()
	if loaded_vfs then return loaded_vfs end

	local candidate = rawget(_G, "vfs")

	if type(candidate) == "table" and type(candidate.LoadFile) == "function" then
		loaded_vfs = candidate
		return loaded_vfs
	end

	local current_import = rawget(_G, "import")

	if current_import and current_import.loaded then
		candidate = current_import.loaded["goluwa/filesystem/vfs.lua"] or
			current_import.loaded["goluwa/vfs.lua"]

		if type(candidate) == "table" and type(candidate.LoadFile) == "function" then
			loaded_vfs = candidate
			return loaded_vfs
		end
	end

	return nil
end

do -- loaders
	local function normalize_path(path)
		local is_absolute = path:sub(1, 1) == "/"
		local parts = {}
		local count = 0
		path = path:gsub("\\", "/")
		path = path:gsub("/+", "/")

		for part in path:gmatch("[^/]+") do
			if part ~= "." and part ~= "" then
				if part == ".." then
					if count > 0 and parts[count] ~= ".." then
						parts[count] = nil
						count = count - 1
					elseif not is_absolute then
						count = count + 1
						parts[count] = part
					end
				else
					count = count + 1
					parts[count] = part
				end
			end
		end

		path = table.concat(parts, "/")

		if is_absolute then path = "/" .. path end

		if path == "" then return is_absolute and "/" or "." end

		if #path > 1 then path = path:gsub("/+$", "") end

		return path
	end

	local function get_base_path(path)
		local base_path = path:match("(.*/)")

		if not base_path then error("could not determine base path") end

		return base_path
	end

	local function get_caller_path(stack_level, this_file)
		if type(this_file) == "table" then this_file = this_file.source end

		this_file = this_file or debug.getinfo(1, "S")
		this_file = type(this_file) == "table" and this_file.source or (this_file or "")

		for level = stack_level or 2, math.huge do
			local info = debug.getinfo(level, "S")

			if not info then break end

			if info.source and info.source:sub(1, 1) == "@" and info.source ~= this_file then
				return normalize_path(info.source:sub(2))
			end
		end

		error("loader must be called from a file")
	end

	local function get_addon_lua_base(path)
		if not path:find("^game/addons/", 1) then return nil end

		return path:match("^(.-/lua/)")
	end

	local function path_loader(name, paths, loader_func)
		local errors = {}
		name = name or ""
		name = name:gsub("%.", "/")

		for path in paths:gmatch("[^;]+") do
			path = path:gsub("%?", name)

			if current_hint and current_hint(path) then  end

			local func, err, path = loader_func(path)

			if func then return func, err, path end

			err = err or "nil"
			table.insert(errors, err)
		end

		table.sort(errors, function(a, b)
			return #a > #b
		end)

		return table.concat(errors, "\n"), paths
	end

	require.NormalizePath = normalize_path
	require.GetBasePath = get_base_path
	require.GetCallerPath = get_caller_path
	require.GetAddonLuaBase = get_addon_lua_base
	require.PathLoader = path_loader
	require.import_path_hooks = {}
	require.searchers = {}

	function require.AddSearcher(searcher, loaders, index)
		loaders = loaders or require.loaders

		if index then
			table.insert(loaders, index, searcher)
		else
			table.insert(loaders, searcher)
		end

		return searcher
	end

	function require.AddImportPathHook(hook)
		table.insert(require.import_path_hooks, hook)
		return hook
	end

	function require.ResolveImportPath(path, current_path, caller_path)
		local is_relative = path:find("./", 1, true) == 1 or path:find("../", 1, true) == 1

		if is_relative then
			local parent_path = current_path or caller_path or get_caller_path(3)
			return normalize_path(get_base_path(parent_path) .. path)
		end

		path = normalize_path(path)

		for _, hook in ipairs(require.import_path_hooks) do
			local new_path = hook(path, current_path, caller_path)

			if type(new_path) == "string" and new_path ~= "" then
				path = normalize_path(new_path)
			end
		end

		return path
	end

	function require.LoadPath(path, chunkname)
		local loaded_vfs = get_vfs()
		local loader = loaded_vfs and loaded_vfs.LoadFile or loadfile
		local func, err, loaded_path = loader(path, chunkname)
		return func, err, loaded_path or path
	end

	function require.MakeLuaSearcher(paths, load_path)
		load_path = load_path or require.LoadPath
		return function(name)
			return path_loader(name, paths, function(path)
				return load_path(path)
			end)
		end
	end

	local function preload_loader(name)
		if type(package.preload[name]) == "function" then
			return package.preload[name], nil, name
		elseif package.preload[name] ~= nil then
			return nil,
			("package.preload[%q] is %q\n"):format(name, type(package.preload[name])),
			nil,
			name
		else
			return nil, ("no field package.preload[%q]\n"):format(name), nil, name
		end
	end

	local function lua_loader(name)
		return require.MakeLuaSearcher(package.path)(name)
	end

	local function c_loader(name)
		local init_func_name = "luaopen_" .. name:gsub("^.*%-", "", 1):gsub("%.", "_")
		return path_loader(name, package.cpath, function(path)
			local func, err, how = package.loadlib(path, init_func_name)
			local loaded_vfs = get_vfs()

			if not func then
				if
					how == "open" and
					not err:starts_with(path)
					or
					(
						loaded_vfs and
						loaded_vfs.IsFile(path)
					)
				then
					local deps = utility.GetLikelyLibraryDependenciesFormatted(full_path)

					if deps then err = err .. "\n" .. deps end
				end
			end

			return func, err, path
		end)
	end

	local function c_loader2(name)
		local symbol

		if name:find(".", nil, true) then
			symbol = "luaopen_" .. name:gsub("^.*%-", "", 1):gsub("%.", "_")
			name = name:match("(.+)%.")
		else
			symbol = "luaopen_" .. name:gsub("^.*%-", "", 1):gsub("%.", "_")
		end

		return path_loader(name, package.cpath, function(path)
			local func, err, how = package.loadlib(path, symbol)
			local loaded_vfs = get_vfs()

			if not func then
				if
					how == "open" and
					not err:starts_with(path)
					or
					(
						loaded_vfs and
						loaded_vfs.IsFile(path)
					)
				then
					err = err .. "\n" .. utility.GetLikelyLibraryDependenciesFormatted(path)
				end
			end

			return func, err, path
		end)
	end

	require.loaders = {}
	require.searchers = require.loaders

	for i, v in ipairs(package.loaders) do
		require.loaders[i] = v
	end

	-- we don't need the default loaders since we reimplement them here
	for i = #require.loaders, 1, -1 do
		if debug.getinfo(require.loaders[i]).what == "C" then
			table.remove(require.loaders, i)
		end
	end

	table.insert(require.loaders, 1, c_loader2)
	table.insert(require.loaders, 1, c_loader)
	table.insert(require.loaders, 1, lua_loader)
	table.insert(require.loaders, 1, preload_loader)
end

function require.load(name, loaders)
	loaders = loaders or require.loaders
	local errors = {}

	for _, loader in ipairs(loaders) do
		local ok, func, msg, path = pcall(loader, name)

		if ok and type(func) == "string" then
			msg = func
			func = nil
		end

		if not ok then
			msg = func
			func = nil
		end

		if func then return func, nil, path else table.insert(errors, msg) end
	end

	if _G[name] then return _G[name], nil, name end

	if not errors[1] then
		errors[1] = string.format("module %q not found\n", name)
	end

	local err = table.concat(errors, "\n")
	err = err:gsub("\n\n", "\n")
	return nil, err, name
end

local function indent_error(str)
	local last_line
	str = "\n" .. str .. "\n"
	str = str:gsub("(.-\n)", function(line)
		line = "\t" .. line:trim() .. "\n"

		if line == last_line then return "" end

		last_line = line
		return line
	end)
	return str
end

function require.require_with_loaders(name, loaders, loaded, arg_override, prepare_func)
	loaded = loaded or package.loaded

	if loaded[name] ~= nil then return loaded[name], nil, name end

	local func, err, path = require.load(name, loaders)

	if not func then return nil, indent_error(err), path end

	local stack_path = path and path:match("(.+)[\\/]")
	local loaded_vfs = get_vfs()

	if loaded_vfs and loaded_vfs.PushToFileRunStack and stack_path then
		loaded_vfs.PushToFileRunStack(stack_path .. "/")
	end

	if prepare_func and type(func) == "function" then
		local new_func = prepare_func(func, path, name)

		if new_func ~= nil then func = new_func end
	end

	local res, call_err = require.require_function(name, func, path, arg_override, loaded)

	if loaded_vfs and loaded_vfs.PopFromFileRunStack and stack_path then
		loaded_vfs.PopFromFileRunStack()
	end

	if res == nil then return nil, indent_error(call_err), path end

	return res, nil, path
end

function require.require(name)
	local res, err = require.require_with_loaders(name)

	if res == nil then error(err, 2) end

	return res
end

function require.module(modname, ...)
	local ns = package.loaded[modname] or {}

	if type(ns) ~= "table" then
		ns = _G[modname]

		if not ns then
			error(string.format("name conflict for module '%s'", modname))
		end

		package.loaded[modname] = ns
	end

	if not ns._NAME then
		ns._NAME = modname
		ns._M = ns
		ns._PACKAGE = modname:gsub("[^.]*$", "")
	end

	for i = 1, select("#", ...) do
		select(i, ...)(ns)
	end

	setfenv(2, ns)
	_G[modname] = ns
end

function require.require_function(name, func, path, arg_override, loaded)
	loaded = loaded or package.loaded

	if loaded[name] == nil and loaded[path] == nil then
		local dir = path

		if dir then dir = dir:match("(.+)[\\/]") end

		local ok, res = pcall(func, arg_override or dir)

		if ok == false then return nil, res end

		if res and not loaded[path] and not loaded[name] then
			loaded[name] = res
		elseif not res and loaded[name] == nil and loaded[path] == nil then
			--wlog("module %s (%s) was required but nothing was returned", name, path)
			loaded[name] = true
		end
	end

	if loaded[path] ~= nil then return loaded[path] end

	return loaded[name]
end

setmetatable(require, {
	__call = function(_, name)
		return require.require(name)
	end,
})
return require
