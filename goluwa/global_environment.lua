-- only load from goluwa/ directory
if not _G._OLD_G then
	local _OLD_G = {}

	if pcall(require, "ffi") then _G.ffi = require("ffi") end

	for k, v in pairs(_G) do
		if k ~= "_G" then
			local t = type(v)

			if t == "function" then
				_OLD_G[k] = v
			elseif t == "table" then
				_OLD_G[k] = {}

				for k2, v2 in pairs(v) do
					if type(v2) == "function" then _OLD_G[k][k2] = v2 end
				end
			end
		end
	end

	_G.ffi = nil
	_G._OLD_G = _OLD_G
end

do
	_G.import = require("goluwa.import")
	_G.require = require("goluwa.require")
	_G.import.loaded["goluwa/import.lua"] = package.loaded["goluwa.import"]
	_G.import.loaded["goluwa/require.lua"] = package.loaded["goluwa.require"]

	local function append_package_path(path)
		if not path or path == "" then return end

		for template in package.path:gmatch("[^;]+") do
			if template == path then return end
		end

		package.path = package.path .. ";" .. path
	end

	append_package_path("bin/LuaJIT/src/?.lua")
	local process = import("goluwa/bindings/process.lua")
	local executable_path = process.get_executable_path and process.get_executable_path() or nil

	if executable_path then
		executable_path = executable_path:gsub("\\", "/")
		local executable_dir = executable_path:match("^(.*)/[^/]+$")

		if executable_dir then append_package_path(executable_dir .. "/?.lua") end
	end
end

import("goluwa/jit/options.lua").SetOptimized()

do
	_G.registered_libs = _G.registered_libs or {}

	function _G.library()
		local key = debug.getinfo(2).source

		if key:sub(1, 1) == "@" then
			key = key:sub(2)
			-- normalize path
			key = key:gsub("^%./", "")
			key = key:gsub("//+", "/")
		end

		if not _G.registered_libs[key] then _G.registered_libs[key] = {} end

		return _G.registered_libs[key]
	end

	function _G.get_libraries()
		local out = {libs = {}, types = {}}

		for key, lib in pairs(registered_libs) do
			local name = key:strip_prefix("goluwa/"):strip_suffix(".lua")
			local parts = name:split("/")
			local out = out.libs

			while #parts > 1 do
				local key = table.remove(parts, 1)

				if not out[key] then out[key] = {} end

				out = out[key]
			end

			out[parts[1]] = lib
		end

		local objects = import("goluwa/objects/objects.lua")

		for name, meta in pairs(objects.GetAllRegistered()) do
			out.types[meta.Type] = meta
		end

		return out
	end
end

_G.list = import("goluwa/list.lua")
_G.setmetatable = import("goluwa/table/setmetatable_gc.lua")
import("goluwa/debug/debug.lua")
import("goluwa/table/table.lua")
import("goluwa/string/string.lua")
import("goluwa/string/string_format.lua")
import("goluwa/math/math.lua")
import("goluwa/globals.lua")

do
	local logging = import("goluwa/cli/logging.lua")
	_G.logf_nospam = logging.LogFormatNoSpam
	_G.logn_nospam = logging.LogNewlineNoSpam
	_G.vprint = logging.VariablePrint
	_G.wlog = logging.WarningLog
	_G.llog = logging.LibraryLog
	_G.log = logging.Log
	_G.logn = logging.LogNewline
	_G.errorf = logging.ErrorFormat
	_G.logf = logging.LogFormat
	_G.logging = logging
end

do
	local event = import("goluwa/event.lua")
	local events = {}
	setmetatable(
		events,
		{
			__index = function(_, event_name)
				assert(type(event_name) == "string")
				return setmetatable(
					{},
					{
						__newindex = function(_, id, func_or_nil)
							if type(func_or_nil) == "function" then
								event.AddListener(event_name, id, func_or_nil)
							elseif funcx_or_nil == nil then
								event.RemoveListener(event_name, id)
							end
						end,
					}
				)
			end,
		}
	)
	_G.events = events
end
