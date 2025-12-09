-- only load from goluwa/ directory
package.path = package.path .. ";" .. "goluwa/?.lua"
require("helpers.jit_options").SetOptimized()
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
