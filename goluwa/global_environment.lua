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

package.path = package.path .. ";" .. "goluwa/?.lua"
require("helpers.jit_options").SetOptimized()

do
	_G.registered_libs = _G.registered_libs or {}

	function _G.library()
		local key = debug.getinfo(2).source

		if not _G.registered_libs[key] then _G.registered_libs[key] = {} end

		return _G.registered_libs[key]
	end
end

_G.list = require("helpers.list")

if _G.PROFILE then require("profiler").Start("init") end

_G.setmetatable = require("helpers.setmetatable_gc")
require("helpers.globals")
require("helpers.debug")
require("helpers.table")
require("helpers.string")
require("helpers.string_format")
require("helpers.math")
_G.table.print = require("helpers.tostring_object").dump_object

do
	local logfile = require("logging")
	_G.logf_nospam = logfile.LogFormatNoSpam
	_G.logn_nospam = logfile.LogNewlineNoSpam
	_G.vprint = logfile.VariablePrint
	_G.wlog = logfile.WarningLog
	_G.llog = logfile.LibraryLog
	_G.log = logfile.Log
	_G.logn = logfile.LogNewline
	_G.errorf = logfile.ErrorFormat
	_G.logf = logfile.LogFormat
	_G.logfile = logfile
end

do
	local event = require("event")
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
