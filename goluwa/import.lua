local import = {}
import.__index = import
import.loaded = {}
import.loading_stack = {}

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

	if not base_path then error("could not determine base path for import") end

	return base_path
end

local function get_addon_lua_base(path)
	if not path:find("^game/addons/", 1) then return nil end

	return path:match("^(.-/lua/)")
end

function import:GetCurrentPath()
	return self.loading_stack[#self.loading_stack]
end

function import:GetCurrentBasePath()
	local path = self:GetCurrentPath()
	return path and get_base_path(path) or nil
end

function import:GetCallerPath(stack_level)
	local this_file = debug.getinfo(1, "S")
	this_file = this_file and this_file.source or ""

	for level = stack_level or 2, math.huge do
		local info = debug.getinfo(level, "S")

		if not info then break end

		if info.source and info.source:sub(1, 1) == "@" and info.source ~= this_file then
			return normalize_path(info.source:sub(2))
		end
	end

	error("import must be called from a file")
end

function import:ResolvePath(path)
	local is_relative = path:find("./", 1, true) == 1 or path:find("../", 1, true) == 1

	if is_relative then
		local parent_path = self:GetCurrentPath() or self:GetCallerPath(2)
		path = normalize_path(get_base_path(parent_path) .. path)
	else
		path = normalize_path(path)

		if path:find("lua/ui/", 1, true) == 1 then
			local parent_path = self:GetCurrentPath() or self:GetCallerPath(2)
			local addon_lua_base = get_addon_lua_base(parent_path)

			if addon_lua_base then
				path = normalize_path(addon_lua_base .. path:sub(5))
			end
		end
	end

	return path
end

import.loadfile = _G.loadfile

function import:__call(path)
	path = self:ResolvePath(path)

	if self.loaded[path] then return self.loaded[path] end

	local chunk, err = self.loadfile(path)

	if not chunk then error("Error loading " .. path .. ": " .. err, 2) end

	self.loading_stack[#self.loading_stack + 1] = path
	local ok, result = xpcall(function()
		return chunk(path)
	end, debug.traceback)
	self.loading_stack[#self.loading_stack] = nil

	if not ok then error(result, 0) end

	self.loaded[path] = result
	return self.loaded[path]
end

setmetatable(import, import)
return import
