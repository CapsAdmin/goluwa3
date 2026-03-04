HOTRELOAD = false
local http = require("http")
local llamacpp = require("llamacpp")
local jinja2 = require("jinja2")

local function get_tool_call_format(model)
	local props = llamacpp.GetProps(model)
	local caps = props.chat_template_caps
	assert(caps, "model has no chat_template_caps")
	assert(caps.supports_tool_calls, "model does not support tool calls")
	assert(caps.supports_tools, "model does not support tools")
	local tmpl = props.chat_template
	assert(tmpl, "model has no chat_template")
	-- render a dummy tool call through the template to discover tags from output
	local SENTINEL_FUNC = "___sentinel_func___"
	local SENTINEL_PARAM = "___sentinel_param___"
	local SENTINEL_VALUE = "___sentinel_value___"
	local SENTINEL_RESULT = "___sentinel_result___"
	local rendered = jinja2.render(
		tmpl,
		{
			messages = {
				{role = "user", content = "x"},
				{
					role = "assistant",
					content = "",
					tool_calls = {
						{
							type = "function",
							["function"] = {
								name = SENTINEL_FUNC,
								arguments = {[SENTINEL_PARAM] = SENTINEL_VALUE},
							},
						},
					},
				},
				{role = "tool", content = SENTINEL_RESULT},
			},
			tools = {
				{
					type = "function",
					["function"] = {name = SENTINEL_FUNC, parameters = {type = "object"}},
				},
			},
			add_generation_prompt = true,
			enable_thinking = false,
		}
	)
	return {
		tool_call_open = assert(rendered:match("\n(<tool_call>)\n<function=")),
		tool_call_close = assert(rendered:match("</function>\n(</tool_call>)")),
		function_open = assert(rendered:match("\n(<function=)[%w_]")),
		parameter_open = assert(rendered:match("\n(<parameter=)[%w_]")),
		tool_response_open = assert(rendered:match("\n(<tool_response>)\n" .. SENTINEL_RESULT)),
		tool_response_close = assert(rendered:match(SENTINEL_RESULT .. "\n(</tool_response>)")),
		eos_token = props.eos_token,
		caps = caps,
		props = props,
	}
end

local function run_lua(args)
	if not args.lua_code then return "missing lua_code argument" end

	local fn, err = loadstring(args.lua_code)

	if not fn then return tostring(err) end

	local ok, result = pcall(fn)
	return ok and tostring(result) or tostring(result)
end

http.async(function()
	local MODEL = "Qwen3.5-35B-A3B-UD-Q4_K_XL_2"
	local fmt = get_tool_call_format(MODEL)
	local tools = {
		{
			type = "function",
			["function"] = {
				name = "lua",
				description = "Run Lua code and return the result",
				parameters = {
					type = "object",
					properties = {
						lua_code = {type = "string"},
					},
					required = {"lua_code"},
				},
			},
		},
	}
	local messages = {
		{role = "user", content = "What is 123 * 456?"},
	}
	local base_prompt = jinja2.render(
		fmt.props.chat_template,
		{
			messages = messages,
			tools = tools,
			add_generation_prompt = true,
			enable_thinking = true,
		}
	)
	local prompt = base_prompt

	while true do
		local generated = ""
		local res = llamacpp.Completion(
			{
				model = MODEL,
				prompt = prompt,
				n_predict = 512,
				stop = {fmt.tool_call_close, fmt.eos_token},
				on_data = function(data)
					generated = generated .. data.content
				end,
			}
		)
		local stop_word = res[#res].stopping_word

		if stop_word == fmt.eos_token or stop_word == "" then
			prompt = prompt .. generated

			break
		end

		if stop_word == fmt.tool_call_close then
			local tool_call = generated:match(".+<tool_call>(.+)$")

			if not tool_call then
				error("failed to parse tool call from generated content")
			end

			local tool_name = tool_call:match("<function=(%w+)>")
			local args = {}

			for param, argument in tool_call:gmatch("<parameter=(.+)>\n(.-)\n</parameter>") do
				args[param] = argument
			end

			if tool_name == "lua" then
				local res = run_lua(args)
				table.insert(
					messages,
					{
						role = "assistant",
						content = generated .. stop_word,
					}
				)
				table.insert(messages, {
					role = "tool",
					content = res,
				})
			else
				error("unknown tool: " .. tostring(tool_name))
			end
		else
			table.print(res[#res])
			error("unexpected stopping word: " .. "|" .. stop_word .. "|")
		end

		local next_full_context = jinja2.render(
			fmt.props.chat_template,
			{
				messages = messages,
				tools = tools,
				add_generation_prompt = false,
				enable_thinking = true,
			}
		)
		prompt = next_full_context
	end

	print("")
	print("")
	print("")
	print(prompt:match("<|im_start|>user(.+)"))
	print("")
	print("")
	print("")
end)