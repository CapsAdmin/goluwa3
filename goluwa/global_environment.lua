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
	package.path = package.path .. ";" .. "bin/LuaJIT/src/?.lua"
end

import("goluwa/helpers/jit_options.lua").SetOptimized()

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
end

_G.list = import("goluwa/helpers/list.lua")
_G.WINDOWS = jit.os == "Windows"
_G.LINUX = jit.os == "Linux"
_G.OSX = jit.os == "OSX"
_G.UNIX = _G.LINUX or _G.OSX

if _G.PROFILE then import("goluwa/profiler.lua").Start("init") end

_G.setmetatable = import("goluwa/helpers/setmetatable_gc.lua")
import("goluwa/helpers/globals.lua")
import("goluwa/helpers/debug.lua")
import("goluwa/helpers/table.lua")
import("goluwa/helpers/string.lua")
import("goluwa/helpers/string_format.lua")
import("goluwa/helpers/math.lua")

do
	local logging = import("goluwa/logging.lua")
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
