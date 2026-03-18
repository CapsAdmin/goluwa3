local utf8 = import("goluwa/utf8.lua")
local event = import("goluwa/event.lua")
local tasks = import("goluwa/tasks.lua")
local prototype = import("goluwa/prototype.lua")
local commands = library()

do
	local function vector(str, ctor)
		local num = str:split(" ")
		local ok = true

		if #num == 3 then
			for i, v in ipairs(num) do
				num[i] = tonumber(v)

				if not num[i] then
					ok = false

					break
				end
			end

			return ctor(unpack(num))
		end

		if not ok then
			local test = str:match("(b())")

			if test then return vector(test:sub(2, -2), ctor) end
		end
	end

	commands.ArgumentTypes = {
		["nil"] = function(str)
			return str
		end,
		self = function(str, me)
			return me
		end,
		vec3 = function(str, me)
			return vector(str, Vec3)
		end,
		ang3 = function(str, me)
			return vector(str, Ang3)
		end,
		vector = function(str, me)
			return vector(str, Vec3)
		end,
		angle = function(str, me)
			return vector(str, Ang3)
		end,
		boolean = function(arg)
			if type(arg) == "boolean" then return arg end

			arg = arg:lower()

			if arg == "1" or arg == "true" or arg == "on" or arg == "yes" or arg == "y" then
				return true
			end

			if arg == "0" or arg == "false" or arg == "off" or arg == "no" or arg == "n" then
				return false
			end

			return false
		end,
		number = function(arg)
			return tonumber(arg)
		end,
		string = function(arg)
			if #arg > 0 then return arg end
		end,
		string_trim = function(arg)
			arg = arg:trim()

			if #arg > 0 then return arg end
		end,
		var_arg = function(arg)
			return arg
		end,
		arg_line = function(arg)
			return arg
		end,
		string_rest = function(arg)
			return arg
		end,
	}

	function commands.StringToType(type, ...)
		return commands.ArgumentTypes[type](...)
	end
end

do -- commands
	commands.added = commands.added or {}
	commands.added2 = commands.added2 or {}
	commands.history = commands.history or {}
	commands.history_map = commands.history_map or {}
	local USER_ERROR_PREFIX = "\1command_user_error:\1"

	function commands.AddHistory(line)
		if not line or line == "" then return end

		if commands.history_map[line] then
			for i, v in ipairs(commands.history) do
				if v == line then
					list.remove(commands.history, i)

					break
				end
			end
		end

		list.insert(commands.history, line)
		commands.history_map[line] = true
	end

	function commands.RaiseUserError(msg, level)
		error(USER_ERROR_PREFIX .. tostring(msg), (level or 1) + 1)
	end

	local capture_symbols = {
		["\""] = "\"",
		["'"] = "'",
		["("] = ")",
		["["] = "]",
		["`"] = "`",
		["´"] = "´",
	}

	local function parse_args(arg_line)
		if not arg_line or arg_line:trim() == "" then return {} end

		local args = {}
		local capture = {}
		local escape = false
		local in_capture = false

		for _, char in ipairs(utf8.to_list(arg_line)) do
			if escape then
				list.insert(capture, char)
				escape = false
			else
				if in_capture then
					if char == in_capture then in_capture = false end

					list.insert(capture, char)
				else
					if char == "," then
						list.insert(args, list.concat(capture, ""))
						list.clear(capture)
					else
						list.insert(capture, char)

						if capture_symbols[char] then in_capture = capture_symbols[char] end

						if char == "\\" then escape = true end
					end
				end
			end
		end

		list.insert(args, list.concat(capture, ""))
		return args
	end

	local function join_args(args, separator)
		local out = {}

		for i, arg in ipairs(args or {}) do
			out[i] = tostring(arg)
		end

		return list.concat(out, separator or " ")
	end

	local function parse_argtypes_definition(aliases, argtypes)
		local defaults

		if type(argtypes) == "string" then argtypes = argtypes:split(",") end

		if not argtypes then return nil, defaults end

		local normalized = {}

		for i, v in ipairs(argtypes) do
			if type(v) == "string" then
				if v:find("|", nil, true) then
					normalized[i] = v:split("|")
				else
					normalized[i] = {v}
				end
			else
				normalized[i] = {}

				for i2, arg in ipairs(v) do
					normalized[i][i2] = arg
				end
			end
		end

		for i, types in ipairs(normalized) do
			for i2, arg in ipairs(types) do
				if type(arg) == "string" and arg:find("[", nil, true) then
					local temp, default = arg:match("(.+)(%b[])")

					if commands.ArgumentTypes[temp] then
						defaults = defaults or {}
						default = default:sub(2, -2)

						if temp == "string" then
							defaults[i] = default
						else
							defaults[i] = commands.StringToType(temp, default)
						end

						types[i2] = temp
					else
						log(aliases[1] .. ": no type information found for \"" .. temp .. "\"")
					end
				end
			end
		end

		return normalized, defaults
	end

	local function normalize_flag_definition(name, def)
		if type(def) == "string" then
			def = {type = def}
		elseif def == true then
			def = {type = "string"}
		elseif def == false or def == nil then
			def = {type = "boolean"}
		end

		local out = {
			name = name,
			type = def.type,
			aliases = def.aliases,
			default = def.default,
			description = def.description,
			has_value = def.has_value,
		}

		if out.aliases == nil then
			out.aliases = {}
		elseif type(out.aliases) == "string" then
			out.aliases = {out.aliases}
		end

		if not out.type then
			if out.has_value == false then
				out.type = "boolean"
			else
				out.type = "string"
			end
		end

		if out.has_value == nil then out.has_value = out.type ~= "boolean" end

		return out
	end

	local function normalize_flags(flags)
		if not flags then return nil end

		local out = {
			by_name = {},
			by_alias = {},
			ordered = {},
		}

		for name, def in pairs(flags) do
			local info = normalize_flag_definition(name, def)
			out.by_name[name] = info
			out.by_alias[name] = info
			list.insert(out.ordered, info)

			for _, alias in ipairs(info.aliases) do
				out.by_alias[alias] = info
			end
		end

		list.sort(out.ordered, function(a, b)
			return a.name < b.name
		end)

		return out
	end

	local function get_flag_info(flags, key)
		if not flags then return nil end

		if flags.by_alias then return flags.by_alias[key] end

		local legacy = flags[key]

		if legacy == nil then return nil end

		if legacy == true then
			return {name = key, type = "string", has_value = true, aliases = {}}
		elseif legacy == false then
			return {name = key, type = "boolean", has_value = false, aliases = {}}
		elseif type(legacy) == "string" then
			return {name = key, type = legacy, has_value = legacy ~= "boolean", aliases = {}}
		elseif type(legacy) == "table" then
			return normalize_flag_definition(key, legacy)
		end
	end

	local function get_flag_names(flags)
		local names = {}

		if not flags then return names end

		if flags.ordered then
			for _, info in ipairs(flags.ordered) do
				list.insert(names, "--" .. info.name)
			end

			return names
		end

		for key in pairs(flags) do
			list.insert(names, "--" .. key)
		end

		list.sort(names, function(a, b)
			return a < b
		end)

		return names
	end

	local function convert_flag_value(info, value)
		if value == nil then return value end

		if not info or not info.type or info.type == "string" then return value end

		local converter = commands.ArgumentTypes[info.type]

		if not converter then
			commands.RaiseUserError("unknown flag type '" .. tostring(info.type) .. "' for --" .. info.name, 3)
		end

		local converted = converter(value)

		if converted == nil then
			commands.RaiseUserError(
				"invalid value for --" .. info.name .. " >>|" .. tostring(value) .. "|<< (expected " .. info.type .. ")",
				3
			)
		end

		return converted
	end

	local function normalize_command_definition(command, callback)
		local aliases
		local argtypes
		local defaults
		local flags
		local final_callback = callback

		if type(command) == "table" then
			aliases = command.aliases or command.command or command.name
			final_callback = command.callback or callback
			argtypes = command.argtypes or command.args
			defaults = command.defaults
			flags = normalize_flags(command.flags)
		else
			aliases = command

			if command:find("=") then
				aliases, argtypes = command:match("(.+)=(.+)")

				if not aliases then aliases = command end
			end
		end

		if type(aliases) == "string" then aliases = aliases:split("|") end

		assert(aliases and aliases[1], "command requires at least one alias")
		assert(type(final_callback) == "function", aliases[1] .. ": callback must be a function")
		local parsed_argtypes, parsed_defaults = parse_argtypes_definition(aliases, argtypes)

		if parsed_defaults then defaults = defaults or parsed_defaults end

		return {
			aliases = aliases,
			argtypes = parsed_argtypes,
			callback = final_callback,
			defaults = defaults,
			flags = flags,
		}
	end

	local start_symbols = {
		"%!",
		"%.",
		"%/",
		"",
	}
	commands.sub_commands = commands.sub_commands or {}

	local function parse_line(line)
		for _, v in ipairs(start_symbols) do
			local start, rest = line:match("^(" .. v .. ")(.+)")

			if start then
				for _, str in ipairs(commands.sub_commands) do
					local cmd, rest_ = rest:match("^(" .. str .. ")%s+(.+)$")

					if cmd then
						return v, cmd, rest_
					else
						local cmd, rest_ = rest:match("^(" .. str .. ")$")

						if cmd then return v, cmd, rest_ end
					end
				end

				local cmd, rest_ = rest:match("^(%S+)%s+(.+)$")

				if not cmd then
					return v, rest:trim()
				else
					return v, cmd, rest_
				end
			end
		end
	end

	function commands.Add(command, callback)
		local spec = normalize_command_definition(command, callback)
		local aliases = spec.aliases
		commands.added[aliases[1]] = spec

		for _, alias in ipairs(aliases) do
			commands.added2[alias] = commands.added[aliases[1]]
		end

		-- sub commands
		if #aliases == 1 and aliases[1]:find(" ", nil, true) then
			if not table.has_value(commands.sub_commands, aliases[1]) then
				list.insert(commands.sub_commands, aliases[1])
			end
		end
	end

	function commands.Remove(alias)
		local command, msg = commands.FindCommand(alias)

		if command then
			commands.added[command.aliases[1]] = nil

			for _, alias in ipairs(command.aliases) do
				commands.added2[alias] = nil
			end

			return true
		end

		return nil, msg
	end

	function commands.FindCommand(str)
		if #str > 50 or str:find("\n", nil, true) then
			return nil, "could not find command: command is too complex"
		end

		local found = {}

		for _, command in pairs(commands.added2) do
			for _, alias in ipairs(command.aliases) do
				if str:lower() == alias:lower() then return command end

				list.insert(
					found,
					{distance = string.levenshtein(str, alias), alias = alias, command = command}
				)
			end
		end

		list.sort(found, function(a, b)
			return a.distance < b.distance
		end)

		return nil,
		"could not find command " .. str .. ". did you mean " .. found[1].alias .. "?"
	end

	function commands.GetCommands()
		return commands.added
	end

	function commands.IsAdded(alias)
		return commands.FindCommand(alias) ~= nil
	end

	function commands.AddHelp(alias, help)
		local command, msg = commands.FindCommand(alias)

		if command then
			command.help = help
			return true
		end

		return nil, msg
	end

	function commands.AddAutoComplete(alias, callback)
		local command, msg = commands.FindCommand(alias)

		if command then
			command.autocomplete = callback
			return true
		end

		return nil, msg
	end

	function commands.GetHelpText(alias)
		local command, msg = commands.FindCommand(alias)

		if not command then return false, msg end

		local str = command.help

		if str then return str end

		local params = {}

		for i = 1, math.huge do
			local key = debug.getlocal(command.callback, i)

			if key then list.insert(params, key) else break end
		end

		str = alias .. " "

		for i = 1, #params do
			local arg_name = params[i]

			if arg_name ~= "_" then
				local types = command.argtypes and command.argtypes[i]
				local default = command.defaults and command.defaults[i]

				if types then
					str = str .. arg_name .. ""
					str = str .. "<"

					for _, type in pairs(types) do
						str = str .. type

						if _ ~= #types then str = str .. " or " end
					end

					str = str .. ">"
				else
					str = str .. "*" .. arg_name .. "*"
				end

				if default then str = str .. " = " .. tostring(default) end

				if i ~= #params then str = str .. ", " end
			end
		end

		local help = alias .. ":\n"
		help = help .. "\tusage example:\n\t\t" .. str .. "\n"

		if command.flags and #command.flags.ordered > 0 then
			help = help .. "\tflags:\n"

			for _, info in ipairs(command.flags.ordered) do
				local line = "\t\t--" .. info.name

				if info.type ~= "boolean" or info.has_value then
					line = line .. " <" .. info.type .. ">"
				end

				if info.default ~= nil then line = line .. " = " .. tostring(info.default) end

				if info.description then line = line .. " - " .. info.description end

				help = help .. line .. "\n"
			end
		end

		help = help .. "\tlocation:\n\t\t" .. debug.get_pretty_source(command.callback, true) .. "\n"
		return help
	end

	function commands.IsCommandStringValid(str)
		return parse_line(str)
	end

	function commands.ParseNamedArgs(args, flags_with_values)
		local positional = {}
		local named = {}
		local i = 1

		while i <= #(args or {}) do
			local arg = args[i]

			if type(arg) == "string" then arg = arg:trim() end

			if arg == "--" then
				for i2 = i + 1, #args do
					list.insert(positional, args[i2])
				end

				local call_args = {}
				local positional_count = #args

				if command.argtypes then
					positional_count = math.max(positional_count, #command.argtypes)
				end

				for i = 1, positional_count do
					call_args[i] = args[i]
				end

				call_args[positional_count + 1] = named_args
				local ret, reason = event.Call("PreCommandExecute", command, alias, unpack(call_args, 1, positional_count + 1))
			elseif type(arg) == "string" and arg:starts_with("--") then
				local key, value = arg:match("^%-%-([^=]+)=(.*)$")
				local info

				if key then
					info = get_flag_info(flags_with_values, key)

					if flags_with_values and not info then
						commands.RaiseUserError(
							"unknown flag --" .. key .. ". expected one of: " .. list.concat(get_flag_names(flags_with_values), ", "),
							2
						)
					end

					named[(info and info.name) or key] = convert_flag_value(info, value)
				else
					key = arg:sub(3)
					info = get_flag_info(flags_with_values, key)

					if flags_with_values and not info then
						commands.RaiseUserError(
							"unknown flag --" .. key .. ". expected one of: " .. list.concat(get_flag_names(flags_with_values), ", "),
							2
						)
					end

					if info and info.has_value then
						i = i + 1

						if args[i] == nil then
							commands.RaiseUserError(
								"missing value for --" .. info.name .. " (expected " .. info.type .. ")",
								2
							)
						end

						named[info.name] = convert_flag_value(info, args[i])
					else
						named[(info and info.name) or key] = true
					end
				end
			else
				list.insert(positional, arg)
			end

			i = i + 1
		end

		return positional, named
	end

	local function find_command(alias, simple)
		local command, err

		if simple then
			if commands.added2[alias] then
				command = commands.added2[alias]
			else
				err = "couldn't find command " .. alias
			end
		else
			command, err = commands.FindCommand(alias)
		end

		return command, err
	end

	local function run_command(command, alias, arg_line, args, rest_separator)
		local named_args

		if command.flags then
			args, named_args = commands.ParseNamedArgs(args, command.flags)

			for _, info in ipairs(command.flags.ordered) do
				if named_args[info.name] == nil and info.default ~= nil then
					named_args[info.name] = info.default
				end
			end
		end

		command.arg_line = arg_line
		local ret, reason = event.Call("PreCommandExecute", command, alias, unpack(args))

		if ret == false then return ret, reason or "no reason" end

		if command.argtypes then
			for i, arg in ipairs(args) do
				if command.argtypes[i] then
					for _, arg_type in ipairs(command.argtypes[i]) do
						if not commands.ArgumentTypes[arg_type] then
							log(alias .. ": no type information found for \"" .. arg_type .. "\"")
						end
					end
				end
			end

			for i, arg_types in ipairs(command.argtypes) do
				if command.defaults and args[i] == nil and command.defaults[i] then
					if command.defaults[i] == "STDIN" then
						logn(alias, " #", i2, " argument (", temp, "):")
						args[i] = io.stdin:read("*l")
					else
						args[i] = command.defaults[i]
					end
				end

				if args[i] ~= nil or not table.has_value(arg_types, "nil") then
					local val

					for _, arg_type in ipairs(arg_types) do
						if arg_type == "arg_line" then
							val = arg_line
						elseif arg_type == "string_rest" then
							val = join_args({select(i, unpack(args))}, rest_separator or ","):trim()
						else
							local test = commands.ArgumentTypes[arg_type](args[i] or "")

							if test ~= nil then
								val = test

								break
							end
						end
					end

					if val == nil and command.defaults and command.defaults[i] and args[i] then
						val = command.defaults[i]
						local err = "unable to convert argument " .. (
								debug.getlocal(command.callback, i) or
								i
							) .. " >>|" .. (
								args[i] or
								""
							) .. "|<< to one of these types: " .. list.concat(command.argtypes[i], ", ") .. "\n"
						err = err .. "defaulting to " .. tostring(command.defaults[i])
						logn(err)
					end

					if val == nil then
						local err = "unable to convert argument " .. (
								debug.getlocal(command.callback, i) or
								i
							) .. " >>|" .. (
								args[i] or
								""
							) .. "|<< to one of these types: " .. list.concat(command.argtypes[i], ", ") .. "\n"
						err = err .. commands.GetHelpText(alias) .. "\n"
						error(err)
					end

					args[i] = val
				end
			end
		end

		if command.flags then
			local call_args = {}
			local positional_count = #args

			if command.argtypes then
				positional_count = math.max(positional_count, #command.argtypes)
			end

			for i = 1, positional_count do
				call_args[i] = args[i]
			end

			call_args[positional_count + 1] = named_args
			return command.callback(unpack(call_args, 1, positional_count + 1))
		end

		return command.callback(unpack(args))
	end

	function commands.ParseString(str, simple)
		local symbol, alias, arg_line = parse_line(str)
		local args = parse_args(arg_line)
		local command, err = find_command(alias, simple)

		if not command then return command, err end

		return command, alias, arg_line, args
	end

	function commands.GetArgLine()
		return command.arg_line or ""
	end

	function commands.RunCommandString(str, simple)
		local command, alias, arg_line, args = assert(commands.ParseString(str, simple))
		return run_command(command, alias, arg_line, args, ",")
	end

	function commands.RunCommandArguments(alias, args, simple)
		args = args or {}
		local command, err = find_command(alias, simple)

		if not command then error(err, 2) end

		return run_command(command, alias, join_args(args, " "), args, " ")
	end

	function commands.ExecuteCommandString(str)
		local tr
		local a, b, c = xpcall(
			commands.RunCommandString,
			function(msg)
				msg = tostring(msg)
				local user_msg = msg:match(USER_ERROR_PREFIX .. "(.*)$")

				if user_msg then return user_msg end

				tr = debug.traceback() .. "\n\n" .. msg
				return tr
			end,
			str,
			simple
		)

		if a == false then return false, b or tr end

		if b == false then
			if tr and c then c = c .. tr end

			return false, c or "unknown reason"
		end

		return true
	end

	function commands.ExecuteCommandArguments(alias, args, simple)
		local tr
		local ok, ret, reason = xpcall(
			commands.RunCommandArguments,
			function(msg)
				msg = tostring(msg)
				local user_msg = msg:match(USER_ERROR_PREFIX .. "(.*)$")

				if user_msg then return user_msg end

				tr = debug.traceback() .. "\n\n" .. msg
				return tr
			end,
			alias,
			args,
			simple
		)

		if ok == false then return false, ret or tr end

		if ret == false then
			if tr and reason then reason = reason .. tr end

			return false, reason or "unknown reason"
		end

		return true
	end

	do
		commands.run_lua_environment = {}

		function commands.SetLuaEnvironmentVariable(key, var)
			commands.run_lua_environment[key] = var
		end

		function commands.RunLuaString(line, env_name)
			commands.SetLuaEnvironmentVariable("steam", desire("steam"))
			commands.SetLuaEnvironmentVariable("vfs", desire("vfs"))
			commands.SetLuaEnvironmentVariable("render3d", desire("render3d.render3d"))
			commands.SetLuaEnvironmentVariable("ffi", desire("ffi"))
			commands.SetLuaEnvironmentVariable("prototype", desire("prototype"))
			commands.SetLuaEnvironmentVariable("findo", prototype.FindObject)

			if WINDOW then
				commands.SetLuaEnvironmentVariable("copy", window.SetClipboard)
			end

			local lua = "local commands = require('commands');"

			for k in pairs(commands.run_lua_environment) do
				lua = lua .. ("local %s = commands.run_lua_environment.%s;"):format(k, k)
			end

			lua = lua .. line
			local ok, err = loadstring(lua, env_name or line)

			if err then err = err:match("^.-:%d+:%s+(.+)") end

			return assert(ok, err)()
		end

		function commands.ExecuteLuaString(line, log_error, env_name)
			local ret = {pcall(commands.RunLuaString, line, env_name)}
			local ok = list.remove(ret, 1)

			if not ok then
				if log_error then logn(ret[1]:match(".+:%d+:%s+(.+)")) end

				return false, ret[1]
			end

			return true, unpack(ret)
		end
	end

	function commands.RunString(line, skip_lua, skip_split)
		if not skip_split and line:find("\n") then
			for line in (line .. "\n"):gmatch("(.-)\n") do
				commands.RunString(line, skip_lua, skip_split)
			end

			return
		end

		local pvars = import("goluwa/pvars.lua")

		if pvars then
			local key, val = line:match("^([%w_]+)%s+(.+)")

			if key and val and pvars.Get(key) ~= nil then
				pvars.SetString(key, val)
				logn(key, " (", pvars.GetObject(key):GetType(), ") = ", pvars.GetString(key))
				return
			end

			local key = line:match("^([%w_]+)$")

			if key and pvars.Get(key) ~= nil then
				logn(key, " (", pvars.GetObject(key):GetType(), ") = ", pvars.GetString(key))
				logn(pvars.GetObject(key):GetHelp())
				return
			end
		end

		local ok, msg = commands.ExecuteCommandString(line)

		if not ok and not msg:find("could not find command") then
			logn(msg)
			return
		end

		if not ok and not skip_lua then
			ok, msg = commands.ExecuteLuaString(line)
		end

		if not ok then
			msg = msg:match("^.-:%d+:%s+(.+)") or msg
			logn(msg)
		end
	end

	function commands.RunArguments(args, skip_lua)
		if not args or not args[1] then return end

		local line = join_args(args, " ")
		local pvars = import("goluwa/pvars.lua")

		if pvars then
			local key, val = line:match("^([%w_]+)%s+(.+)")

			if key and val and pvars.Get(key) ~= nil then
				pvars.SetString(key, val)
				logn(key, " (", pvars.GetObject(key):GetType(), ") = ", pvars.GetString(key))
				return
			end

			local key = line:match("^([%w_]+)$")

			if key and pvars.Get(key) ~= nil then
				logn(key, " (", pvars.GetObject(key):GetType(), ") = ", pvars.GetString(key))
				logn(pvars.GetObject(key):GetHelp())
				return
			end
		end

		local alias = args[1]
		local command_args = {}

		for i = 2, #args do
			command_args[i - 1] = args[i]
		end

		local ok, msg = commands.ExecuteCommandArguments(alias, command_args)

		if not ok and not msg:find("could not find command") then
			logn(msg)
			return
		end

		if not ok and not skip_lua then
			ok, msg = commands.ExecuteLuaString(line)
		end

		if not ok then
			msg = msg:match("^.-:%d+:%s+(.+)") or msg
			logn(msg)
		end
	end

	commands.Add("help|usage=string|nil", function(cmd)
		if not cmd then
			for k, v in table.sorted_pairs(commands.GetCommands()) do
				logn(assert(commands.GetHelpText(k)))
			end
		else
			local help, err = commands.GetHelpText(cmd)

			if help then
				logn(help)
			else
				for _, sub_cmd in ipairs(commands.sub_commands) do
					if sub_cmd:starts_with(cmd) then
						logn(assert(commands.GetHelpText(sub_cmd)))
					end
				end
			end
		end
	end)
end

return commands
