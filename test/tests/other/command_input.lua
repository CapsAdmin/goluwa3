local T = import("test/environment.lua")
local commands = import("goluwa/cli/commands.lua")
local pvars = import("goluwa/cli/pvars.lua")
local logging = import("goluwa/cli/logging.lua")
local autocomplete = import("goluwa/autocomplete.lua")
local command_input = import("goluwa/cli/command_input.lua")

local function with_command(spec, callback, fn)
	commands.Add(spec, callback)
	local ok, err = pcall(fn)
	commands.Remove(type(spec) == "string" and spec:match("^[^=|]+") or spec.name)

	if not ok then error(err, 0) end
end

local function values(results)
	local out = {}

	for i, result in ipairs(results) do
		out[i] = result.val
	end

	return table.concat(out, ",")
end

T.Test("logging capture collects output and restores the logger", function()
	local original = logging.RawLog
	local output, a, b = logging.Capture(function(x)
		logn("one")
		log("two")
		return x, "second"
	end, "first")
	T(output)["=="]("one\ntwo")
	T(a)["=="]("first")
	T(b)["=="]("second")
	T(logging.RawLog)["=="](original)
	local ok = pcall(logging.Capture, function()
		error("boom", 0)
	end)
	T(ok)["=="](false)
	T(logging.RawLog)["=="](original)
end)

T.Test("commands usage shows arguments, defaults, optional arguments and flags", function()
	with_command("test_usage_command=string,number[3],boolean|nil", function(name, count, enabled) end, function()
		T(commands.GetUsage(commands.added.test_usage_command))["=="]("test_usage_command <name: string> [count: number = 3] [enabled: boolean]")
	end)

	with_command({name = "test_usage_flags", flags = {verbose = "boolean"}}, function(flags) end, function()
		T(commands.GetUsage(commands.added.test_usage_flags))["=="]("test_usage_flags [--verbose]")
	end)

	with_command("test_usage_plain", function() end, function()
		T(commands.GetUsage(commands.added.test_usage_plain))["=="]("test_usage_plain")
	end)
end)

T.Test("commands run line returns failures instead of printing them", function()
	with_command("test_run_line=string", function(text)
		logn("ran ", text)
	end, function()
		local output, ok = logging.Capture(commands.RunLine, "test_run_line hello")
		T(output)["=="]("ran hello\n")
		T(ok)["=="](true)
	end)

	local _, ok, message, short = logging.Capture(commands.RunLine, "no_such_command_here 1")
	T(ok)["=="](false)
	T(short:find("could not find command no_such_command_here", nil, true) ~= nil)["=="](true)
	T(short:find("\n", nil, true))["=="](nil)
end)

T.Test("commands run line sets and shows pvars", function()
	pvars.Setup2{key = "test_run_line_var", default = 2, store = false, help = "a test var"}
	local output, ok = logging.Capture(commands.RunLine, "test_run_line_var 5")
	T(ok)["=="](true)
	T(output:find("test_run_line_var (number) = 5", nil, true) ~= nil)["=="](true)
	T(pvars.Get("test_run_line_var"))["=="](5)
	local _, bad, _, short = logging.Capture(commands.RunLine, "test_run_line_var abc")
	T(bad)["=="](false)
	T(short:find("expected a number", nil, true) ~= nil)["=="](true)
end)

T.Test("autocomplete accepts inline entries, no filter lists, details and hints", function()
	local entries = {
		{
			id = "inline_a",
			source = {{val = "alpha", detail = "first"}, "beta"},
			options = {},
		},
		{
			id = "inline_hint",
			source = {{val = "", detail = "usage here", hint = true}},
			options = {NoFilter = true},
		},
	}
	local results = autocomplete.Search("alp", {Lists = entries, MatchEmpty = true})
	T(values(results))["=="]("alpha,")
	T(results[1].detail)["=="]("first")
	T(results[2].hint)["=="](true)
	T(results[2].detail)["=="]("usage here")
end)

T.Test("autocomplete alphabetical lists sort matches by name", function()
	local entry = {
		id = "alpha_list",
		source = {"zed", "bob", "amy", "cat"},
		options = {Alphabetical = true},
	}
	T(values(autocomplete.Search("", {Lists = {entry}, MatchEmpty = true})))["=="]("amy,bob,cat,zed")
end)

T.Test("autocomplete sessions skip hints for selection and completion", function()
	local session = autocomplete.NewSession{
		GetQuery = function(text)
			return text,
			"",
			{
				{
					id = "hint",
					source = {{val = "", detail = "syntax", hint = true}},
					options = {NoFilter = true},
				},
				{id = "values", source = {"one", "two"}, options = {}},
			},
			true
		end,
	}
	session:SetText("cmd ")
	T(#session:GetResults())["=="](3)
	T(session:GetSelectedIndex())["=="](2)
	T(session:GetCompletion())["=="]("cmd one")
	session:Move(1)
	T(session:GetSelectedIndex())["=="](3)
	session:Move(1)
	T(session:GetSelectedIndex())["=="](2)
	local hint_only = autocomplete.NewSession{
		GetQuery = function(text)
			return text,
			"",
			{
				{
					id = "hint",
					source = {{val = "", detail = "x", hint = true}},
					options = {NoFilter = true},
				},
			},
			true
		end,
	}
	hint_only:SetText("cmd ")
	T(hint_only:HasResults())["=="](true)
	T(hint_only:HasSelectable())["=="](false)
	T(hint_only:Cycle(1))["=="](nil)
	T(hint_only:GetGhost())["=="]("")
end)

T.Test("command input only treats the prefix as a command", function()
	T(command_input.IsCommand("!help"))["=="](true)
	T(command_input.IsCommand("help"))["=="](false)
	local prefix, query, lists = command_input.GetQuery("hello there")
	T(prefix)["=="]("")
	T(query)["=="]("hello there")
	T(lists)["=="](nil)
end)

T.Test("command input completes command and variable names with their syntax", function()
	with_command("test_complete_cmd=string,number[3]", function(name, count) end, function()
		pvars.Setup2{key = "test_complete_var", default = true, store = false, help = "toggles it"}
		local session = command_input.NewSession()
		session:SetText("!test_comp")
		local results = session:GetResults()
		T(values(results))["=="]("test_complete_cmd,test_complete_var")
		T(results[1].detail)["=="]("<name: string> [count: number = 3]")
		T(results[1].id)["=="]("console_commands")
		T(results[2].detail)["=="]("boolean = true  toggles it")
		T(session:GetCompletion())["=="]("!test_complete_cmd")
		T(session:GetGhost())["=="]("lete_cmd")
		session:SetText("!")
		T(#session:GetResults())[">"](2)
	end)
end)

T.Test("command input shows the syntax after a command name and values after a variable", function()
	with_command("test_hint_cmd=string,number[3]", function(name, count) end, function()
		local session = command_input.NewSession()
		session:SetText("!test_hint_cmd ")
		T(session:GetResults()[1].hint)["=="](true)
		T(session:GetResults()[1].detail)["=="]("test_hint_cmd <name: string> [count: number = 3]")
		T(session:HasSelectable())["=="](false)
	end)

	pvars.Setup2{
		key = "test_hint_mode",
		default = "fast",
		enums = {"fast", "slow", "safe"},
		store = false,
	}
	local session = command_input.NewSession()
	session:SetText("!test_hint_mode s")
	T(values(session:GetResults()))["=="](",slow,safe,fast")
	T(session:GetCompletion())["=="]("!test_hint_mode slow")
	pvars.Setup2{key = "test_hint_flag", default = false, store = false}
	session:SetText("!test_hint_flag ")
	T(values(session:GetResults()))["=="](",true,false")
	session:SetText("!unknown_thing ")
	T(#session:GetResults())["=="](0)
end)

T.Test("command input runs commands and reports output and errors", function()
	with_command("test_input_run=string", function(text)
		logn("got ", text)
	end, function()
		local output, ok = command_input.Run("!test_input_run hi")
		T(output)["=="]("got hi\n")
		T(ok)["=="](true)
	end)

	local output, ok, message = command_input.Run("!no_such_input_command")
	T(output)["=="]("")
	T(ok)["=="](false)
	T(message:find("could not find command", nil, true) ~= nil)["=="](true)

	with_command("test_input_multi", function()
		logn("line")
	end, function()
		T((command_input.Run("!test_input_multi\n!test_input_multi")))["=="]("line\nline\n")
	end)
end)
