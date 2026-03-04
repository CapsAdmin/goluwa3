HOTRELOAD = false
local http = require("http")
local llamacpp = require("llamacpp")
local codec = require("codec")
local event = require("event")
local colors = require("helpers.colors")
local MODEL = "Qwen3.5-35B-A3B-UD-Q4_K_XL_2"
local PROMPT = "what os am i running?"
local tools = {
	lua = {
		description = "runs arbitrary luajit code. there is no stdout, so you must return the result.",
		parameters = {
			type = "object",
			properties = {
				lua_code = {type = "string"},
			},
			required = {"lua_code"},
		},
		func = function(args)
			if not args.lua_code then return "missing lua_code argument" end

			local fn, err = loadstring(args.lua_code)

			if not fn then return tostring(err) end

			local ok, result = pcall(fn)

			if result == nil then return "no output, did you forget to return anything?" end

			return ok and tostring(result) or tostring(result)
		end,
	},
}

local function run_tool(name, args)
	if not tools[name] then return "unknown tool: " .. tostring(name) end

	local result = tools[name].func(args)
	io.write(colors.yellow("tool:\n" .. tostring(result) .. "\n"))
	return result
end

local available_tools = {}

for k, v in pairs(tools) do
	table.insert(
		available_tools,
		{
			name = k,
			type = "function",
			["function"] = {
				name = k,
				description = v.description,
				parameters = v.parameters,
			},
		}
	)
end

http.async(function()
	local active_tools = {}
	local messages = {
		{role = "user", content = PROMPT},
	}
	local should_run = true

	while should_run do
		local res = llamacpp.ChatCompletion(
			{
				model = MODEL,
				messages = messages,
				tools = available_tools,
				on_data = function(data)
					for _, choice in ipairs(data.choices) do
						if choice.delta.role then
							io.write(tostring(choice.delta.role) .. ":\n")
							io.flush()
						elseif choice.delta.content then
							io.write(tostring(choice.delta.content))
							io.flush()
						elseif choice.delta.reasoning_content then
							io.write(colors.dim(tostring(choice.delta.reasoning_content)))
							io.flush()
						elseif choice.delta.tool_calls then
							for _, tc in ipairs(choice.delta.tool_calls) do
								if tc.type == "function" then
									active_tools = active_tools or {}
									local idx = tc.index + 1
									active_tools[idx] = {id = tc.id, name = tc["function"].name, type = "function", arguments = ""}
									active_tools[idx].arguments = active_tools[idx].arguments .. tc["function"].arguments
								elseif tc["function"] then
									local idx = tc.index + 1
									active_tools[idx].arguments = active_tools[idx].arguments .. tc["function"].arguments
								else
									error("unknown tool type: " .. tostring(tc.type))
								end
							end
						elseif choice.finish_reason == "stop" then
							should_run = false
						elseif choice.finish_reason == "tool_calls" then

						-- this is done at the end of the loop
						else
							table.print(choice)
							error("unknown delta content")
						end
					end
				end,
			}
		)

		for _, tc in ipairs(active_tools) do
			if tc.type == "function" then
				local args = codec.Decode("json", tc.arguments or "")
				local result = run_tool(tc.name, args)
				io.flush()
				table.insert(
					messages,
					{
						role = "tool",
						tool_call_id = tc.id,
						content = result,
					}
				)
			else
				error("unknown tool type: " .. tostring(tc.type))
			end
		end

		table.clear(active_tools)
	end

	io.write("\n")
	io.flush()
end)