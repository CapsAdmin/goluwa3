local import = {}
import.__index = import
import.loaded = {}
import.loading_stack = {}
import.loading = {}
local require = require("goluwa.require")

function import:GetCurrentPath()
	return self.loading_stack[#self.loading_stack]
end

function import:GetCurrentBasePath()
	local path = self:GetCurrentPath()
	return path and require.GetBasePath(path) or nil
end

function import:GetCallerPath(stack_level)
	return require.GetCallerPath(stack_level or 2, debug.getinfo(1, "S").source)
end

function import:ResolvePath(path)
	local current_path = self:GetCurrentPath()
	local caller_path

	if
		path:find("./", 1, true) == 1 or
		path:find("../", 1, true) == 1 or
		path:find("lua/ui/", 1, true) == 1
	then
		caller_path = self:GetCallerPath(2)
	end

	return require.ResolveImportPath(path, current_path, caller_path)
end

import.loadfile = _G.loadfile

function import:__call(path)
	path = self:ResolvePath(path)

	if self.loaded[path] then return self.loaded[path] end

	if self.loading[path] then
		error("import loop detected while loading " .. path, 2)
	end

	self.loading[path] = true
	local chunk, err = self.loadfile(path)

	if not chunk then
		self.loading[path] = nil
		error("Error loading " .. path .. ": " .. err, 2)
	end

	self.loading_stack[#self.loading_stack + 1] = path
	local ok, result = xpcall(function()
		return chunk(path)
	end, debug.traceback)
	self.loading_stack[#self.loading_stack] = nil
	self.loading[path] = nil

	if not ok then error(result, 0) end

	self.loaded[path] = result
	return self.loaded[path]
end

setmetatable(import, import)
return import
