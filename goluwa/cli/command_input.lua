local commands = import("goluwa/cli/commands.lua")
local pvars = import("goluwa/cli/pvars.lua")
local logging = import("goluwa/cli/logging.lua")
local autocomplete = import("goluwa/autocomplete.lua")
local command_input = {}
command_input.Prefix = "!"
autocomplete.SetListName("console_commands", "Commands")
autocomplete.SetListName("console_variables", "Variables")
autocomplete.SetListName("console_values", "Values")
local scalar_types = {string = true, number = true, boolean = true}

local function describe_variable(key, info)
	local text = info.type

	if scalar_types[info.type] then
		text = text .. " = " .. tostring(pvars.Get(key))
	end

	if info.help then text = text .. "  " .. info.help end

	return text
end

local commands_entry = {
	id = "console_commands",
	options = {Alphabetical = true},
	source = function()
		local entries = {}

		for _, command in pairs(commands.GetCommands()) do
			local detail = commands.GetUsage(command):match("^%S+%s*(.*)")

			for _, alias in ipairs(command.aliases) do
				if alias:sub(1, 1) ~= "-" then
					entries[#entries + 1] = {val = alias, detail = detail}
				end
			end
		end

		table.sort(entries, function(a, b)
			return a.val < b.val
		end)

		return entries
	end,
}
local variables_entry = {
	id = "console_variables",
	options = {Alphabetical = true},
	source = function()
		local entries = {}

		for key, info in pairs(pvars.GetAll()) do
			entries[#entries + 1] = {val = key, detail = describe_variable(key, info)}
		end

		table.sort(entries, function(a, b)
			return a.val < b.val
		end)

		return entries
	end,
}

local function create_hint(text)
	return {
		id = "console_hint",
		options = {NoFilter = true},
		source = {{val = "", detail = text, hint = true}},
	}
end

function command_input.IsCommand(text)
	return text:sub(1, #command_input.Prefix) == command_input.Prefix
end

function command_input.GetQuery(text)
	if not command_input.IsCommand(text) then return "", text end

	local rest = text:sub(#command_input.Prefix + 1)
	local name, space = rest:match("^(%S*)(%s*)")

	if space == "" then
		return command_input.Prefix, name, {commands_entry, variables_entry}, true
	end

	local info = pvars.GetAll()[name]

	if info then
		local token = text:match("(%S*)$")
		local values = info.enums

		if not values and info.type == "boolean" then values = {"true", "false"} end

		local hint = name .. ": " .. describe_variable(name, info)
		return text:sub(1, #text - #token),
		token,
		{
			create_hint(hint),
			{id = "console_values", options = {}, source = values or {}},
		},
		true
	end

	local command = commands.added2[name] or commands.added2[name:lower()]

	if command then
		return text, "", {create_hint(commands.GetUsage(command))}, true
	end

	return text, "", {}, true
end

function command_input.NewSession(config)
	config = config or {}
	config.GetQuery = command_input.GetQuery
	return autocomplete.NewSession(config)
end

function command_input.Run(text)
	local output = {}
	local ok = true
	local message

	for line in (text:sub(#command_input.Prefix + 1) .. "\n"):gmatch("(.-)\n") do
		line = line:trim()

		if line ~= "" then
			local logged, line_ok, _, short = logging.Capture(commands.RunLine, line)
			output[#output + 1] = logged

			if not line_ok then
				ok = false
				message = short
			end
		end
	end

	return table.concat(output), ok, message
end

return command_input
