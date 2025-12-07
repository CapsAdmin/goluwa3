-- only load from goluwa/ directory
package.path = package.path .. ";" .. "goluwa/?.lua"

if _G.PROFILE then require("profiler").Start("init") end

_G.setmetatable = require("helpers.setmetatable_gc")
require("helpers.globals")
require("helpers.debug")
require("helpers.table")
require("helpers.string")
require("helpers.string_format")
require("helpers.math")
_G.table.print = require("helpers.tostring_object").dump_object
_G.list = require("helpers.list")

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
