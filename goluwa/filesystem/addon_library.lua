local module_require = require("goluwa.require")
local vfs = import("goluwa/filesystem/vfs.lua")
local addon_library = vfs.addon_library or {}
vfs.addon_library = addon_library
addon_library.module_directories = addon_library.module_directories or {}

local function push_error(errors, err)
	err = err or "nil"

	if errors[#errors] ~= err then list.insert(errors, err) end
end

local function build_directory_search_paths(dir)
	dir = dir:gsub("\\", "/")

	if not dir:ends_with("/") then dir = dir .. "/" end

	local paths = {}

	for template in package.path:gmatch("[^;]+") do
		template = template:gsub("\\", "/")

		if template:find("^%./") then list.insert(paths, dir .. template:sub(3)) end
	end

	if not paths[1] then
		paths[1] = dir .. "?.lua"
		paths[2] = dir .. "?/init.lua"
	end

	return list.concat(paths, ";")
end

local function search_directories(module_name, directories)
	local errors = {}

	for _, dir in ipairs(directories) do
		for _, data in ipairs(vfs.TranslatePath(dir, true)) do
			local func, err, path = module_require.PathLoader(
				module_name,
				build_directory_search_paths(data.path_info.full_path),
				module_require.LoadPath
			)

			if func then return func, nil, path end

			push_error(errors, err or ("no file in: " .. data.path_info.full_path))
		end
	end

	if errors[1] then return nil, list.concat(errors, "\n"), nil end
end

local function get_addon_lua_directories()
	local directories = {}

	for _, info in ipairs(vfs.loaded_addons or {}) do
		local dir = info.path .. "lua/"

		if vfs.IsDirectory(dir) then list.insert(directories, dir) end
	end

	return directories
end

local function get_module_directories()
	return addon_library.module_directories
end

local function get_file_run_directory()
	local stack = vfs.GetFileRunStack()
	local last = stack[#stack]

	if not last then return {} end

	local dir = vfs.GetFolderFromPath(last)

	if dir then return {dir} end

	return {}
end

function addon_library.MakeDirectorySearcher(get_directories)
	return function(module_name)
		return search_directories(module_name, get_directories())
	end
end

function addon_library.AddModuleDirectory(dir, loaders)
	if loaders then
		return module_require.AddSearcher(addon_library.MakeDirectorySearcher(function()
			return {dir}
		end), loaders, 1)
	end

	list.insert(addon_library.module_directories, dir)
	return dir
end

module_require.AddImportPathHook(function(path, current_path, caller_path)
	if path:find("lua/ui/", 1, true) ~= 1 then return path end

	local parent_path = current_path or caller_path

	if not parent_path then return path end

	local addon_lua_base = module_require.GetAddonLuaBase(parent_path)

	if addon_lua_base then return addon_lua_base .. path:sub(5) end

	return path
end)

module_require.AddSearcher(addon_library.MakeDirectorySearcher(get_file_run_directory), nil, 1)
module_require.AddSearcher(addon_library.MakeDirectorySearcher(get_module_directories), nil, 1)
module_require.AddSearcher(addon_library.MakeDirectorySearcher(get_addon_lua_directories), nil, 1)
return addon_library
