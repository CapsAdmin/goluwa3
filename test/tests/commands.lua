local test = require("helpers.test")
local attest = require("helpers.attest")
local commands = require("commands")

local function with_temp_command(spec, callback, cb)
	if cb == nil then
		cb = callback
		callback = nil
	end

	local aliases

	if type(spec) == "table" then
		aliases = spec.aliases or spec.command or spec.name
	else
		aliases = spec:match("([^=]+)") or spec
	end

	local primary = type(aliases) == "table" and aliases[1] or aliases
	commands.Remove(primary)

	if callback then commands.Add(spec, callback) else commands.Add(spec) end

	local ok, err = xpcall(cb, debug.traceback)
	commands.Remove(primary)

	if not ok then error(err, 0) end
end

test.Test("commands legacy spec keeps comma syntax", function()
	with_temp_command("__test_commands_legacy_string=string,number", function(name, count)
		attest.equal(name, "alpha")
		attest.equal(count, 42)
	end, function()
		commands.RunCommandString("__test_commands_legacy_string alpha, 42")
	end)
end)

test.Test("commands legacy spec parses argv positionals", function()
	with_temp_command("__test_commands_legacy_argv=string,number", function(name, count)
		attest.equal(name, "alpha")
		attest.equal(count, 42)
	end, function()
		commands.RunCommandArguments("__test_commands_legacy_argv", {"alpha", "42"})
	end)
end)

test.Test("commands legacy spec does not parse flags", function()
	with_temp_command("__test_commands_legacy_raw", function(...)
		local args = {...}
		attest.equal(args[1], "alpha")
		attest.equal(args[2], "--verbose")
		attest.equal(#args, 2)
	end, function()
		commands.RunCommandArguments("__test_commands_legacy_raw", {"alpha", "--verbose"})
	end)
end)

test.Test("commands table spec parses argv flags", function()
	with_temp_command({
		aliases = "__test_commands_argv_flags",
		argtypes = "string,number",
		flags = {
			filter = "string",
			limit = "number",
			verbose = "boolean",
		},
		callback = function(name, count, flags)
			attest.equal(name, "alpha")
			attest.equal(count, 42)
			attest.equal(flags.filter, "ogg")
			attest.equal(flags.limit, 3)
			attest.equal(flags.verbose, true)
		end,
	}, function()
		commands.RunCommandArguments(
			"__test_commands_argv_flags",
			{"alpha", "42", "--filter=ogg", "--limit", "3", "--verbose"}
		)
	end)
end)

test.Test("commands table spec keeps comma syntax", function()
	with_temp_command({
		aliases = "__test_commands_string_flags",
		argtypes = "string",
		flags = {
			filter = "string",
			verbose = "boolean",
		},
		callback = function(name, flags)
			attest.equal(name, "alpha")
			attest.equal(flags.filter, "ogg")
			attest.equal(flags.verbose, true)
		end,
	}, function()
		commands.RunCommandString("__test_commands_string_flags alpha, --filter=ogg, --verbose")
	end)
end)

test.Test("commands table spec rejects unknown flags", function()
	with_temp_command({
		aliases = "__test_commands_bad_flag",
		flags = {
			verbose = "boolean",
		},
		callback = function(flags)
			return flags
		end,
	}, function()
		local ok, err = commands.ExecuteCommandArguments("__test_commands_bad_flag", {"--wat"})
		attest.falsy(ok)
		attest.contains(err, "unknown flag --wat")
		attest.contains(err, "--verbose")
		attest.falsy(err:find("stack traceback", 1, true))
	end)
end)

test.Test("commands table spec passes flags without positionals", function()
	with_temp_command({
		aliases = "__test_commands_flags_only",
		flags = {
			verbose = "boolean",
		},
		callback = function(flags)
			attest.equal(flags.verbose, true)
		end,
	}, function()
		commands.RunCommandArguments("__test_commands_flags_only", {"--verbose"})
	end)
end)

test.Test("test command rejects unknown flags", function()
	local test_command = commands.IsAdded("test") and "test" or "test2"
	local ok, err = commands.ExecuteCommandArguments(test_command, {"--wat", "--no-separate", "--no-summary"})
	attest.falsy(ok)
	attest.contains(err, "unknown flag --wat")
	attest.contains(err, "--filter")
	attest.contains(err, "--no-separate")
	attest.falsy(err:find("stack traceback", 1, true))
end)
