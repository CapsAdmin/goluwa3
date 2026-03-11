local output = require("output")
local list_concat = table.concat
local select = select
local logging = library()

function logging.ReplMode()
	output.Initialize()
	logging.RawLog = output.Write
end

function logging.RawLog(str)
	io.write(str)
end

function logging.Log(...)
	logging.RawLog(list_concat(tostring_args(...)))
	return ...
end

function logging.LogNewline(...)
	logging.RawLog(list_concat(tostring_args(...)) .. "\n")
	return ...
end

function logging.Print(...)
	logging.RawLog(list_concat(tostring_args(...), ",\t") .. "\n")
	return ...
end

do
	local function format(str, ...)
		local args = list.pack(...)

		for i, chunk in ipairs(str:split("%")) do
			if i > 1 then
				if chunk:starts_with("s") then args[i] = tostringx(args[i]) end
			end
		end

		return str:format(unpack(args))
	end

	function logging.LogFormat(str, ...)
		logging.RawLog(format(str, ...))
		return ...
	end

	function logging.ErrorFormat(str, level, ...)
		error(format(str, ...), level)
	end
end

do
	local level = 1

	function logging.SourceLevel(n)
		if n then level = n end

		return level
	end
end

-- library log
function logging.LibraryLog(fmt, ...)
	fmt = tostringx(fmt)
	local level = tonumber(select(fmt:count("%") + 1, ...) or 1) or 1
	local source = debug.get_pretty_source(level + 1, false, true)
	local main_category = source:match(".+/libraries/(.-)/")
	local sub_category = source:match(".+/libraries/.-/(.-)/") or source:match(".+/(.-)%.lua")

	if sub_category == "libraries" then
		sub_category = source:match(".+/libraries/(.+)%.lua")
	end

	if main_category == "extensions" then main_category = nil end

	local str = fmt:safe_format(...)

	if not main_category or not sub_category or main_category == sub_category then
		return logf(
			"[%s] %s\n",
			main_category or
				sub_category or
				vfs.RemoveExtensionFromPath(vfs.GetFileNameFromPath(source)),
			str
		)
	else
		return logf("[%s][%s] %s\n", main_category, sub_category, str)
	end

	return str
end

-- warning log
function logging.WarningLog(fmt, ...)
	fmt = tostringx(fmt)
	local level = tonumber(select(fmt:count("%") + 1, ...) or 1) or 1
	local str = fmt:safe_format(...)
	local source = debug.get_pretty_source(level + 1, true)
	logging.LogNewline(source, ": ", str)
	return fmt, ...
end

do
	local codec = require("codec")

	function logging.VariablePrint(...)
		logf("%s:\n", debug.getinfo(logging.SourceLevel() + 1, "n").name or "unknown")

		for i = 1, select("#", ...) do
			local name = debug.getlocal(logging.SourceLevel() + 1, i)
			local arg = select(i, ...)
			logf(
				"\t%s:\n\t\ttype: %s\n\t\tprty: %s\n",
				name or "arg" .. i,
				type(arg),
				tostring(arg),
				codec.Encode("luadata", arg)
			)

			if type(arg) == "string" then logging.LogNewline("\t\tsize: ", #arg) end

			if typex(arg) ~= type(arg) then logging.LogNewline("\t\ttypx: ", typex(arg)) end
		end
	end
end

do -- nospam
	local system = require("system")
	local last = {}

	function logging.LogFormatNoSpam(str, ...)
		local str = string.format(str, ...)
		local t = system.GetElapsedTime()

		if not last[str] or last[str] < t then
			logging.LogNewline(str)
			last[str] = t + 3
		end
	end

	function logging.LogNewlineNoSpam(...)
		logging.LogFormatNoSpam(("%s "):rep(select("#", ...)), ...)
	end
end

return logging
