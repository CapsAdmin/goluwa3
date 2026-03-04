HOTRELOAD = false
local http = require("http")
local llamacpp = require("llamacpp.api")
local codec = require("codec")
local colors = require("helpers.colors")
local prototype = require("prototype")
local Agent = prototype.CreateTemplate("llamacpp_agent")
Agent:GetSet("Tools", require("llamacpp.tools"))
Agent:GetSet("Messages")
Agent:GetSet("Model", "Qwen3.5-35B-A3B-UD-Q4_K_XL_2")

function Agent.New(model)
	return Agent:CreateObject(
		{
			Tools = {},
			Messages = {},
			Model = model or Agent.Model,
			message_queue = {},
		}
	)
end

function Agent:AddMessage(msg)
	table.insert(self.Messages, msg)
end

function Agent:QueueMessage(msg)
	table.insert(self.message_queue, msg)
end

function Agent:ToolCall(name, args)
	local tools = self:GetTools()

	if not tools[name] then return "unknown tool: " .. tostring(name) end

	for k, v in pairs(tools[name].parameters.required) do
		if args[v] == nil then return "missing required argument: " .. k end
	end

	local ok, res = pcall(tools[name].func, args)

	do
		if name == "lua" then
			io.write(colors.yellow("tool-" .. name .. ":" .. args.lua_code .. "\n"))
		else
			io.write(colors.yellow("tool-" .. name .. ":" .. table.tostring(args) .. "\n"))
		end
	end

	if not ok then
		io.write(colors.red("<< " .. tostring(res) .. "\n"))
		return "error: " .. tostring(res)
	end

	res = table.tostring(res)
	io.write(colors.yellow("<< " .. res .. "\n"))
	return res
end

function Agent:Run()
	http.async(function()
		local active_tools = {}
		local should_run = true

		while should_run do
			local available_tools = {}

			for k, v in pairs(self:GetTools()) do
				table.insert(
					available_tools,
					{
						type = "function",
						["function"] = {
							name = k,
							description = v.description,
							parameters = v.parameters,
						},
					}
				)
			end

			local res = llamacpp.ChatCompletion(
				{
					model = self:GetModel(),
					temperature = 0.6,
					top_p = 0.95,
					top_k = 20,
					min_p = 0.0,
					--
					messages = self:GetMessages(),
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
									local idx = tc.index + 1

									if tc.id then
										active_tools[idx] = {
											id = tc.id,
											name = tc["function"].name,
											type = "function",
											arguments = tc["function"].arguments or "",
										}
										io.write(
											colors.yellow(
												"\n[Tool call: " .. tc["function"].name .. " with arguments: " .. (
														tc["function"].arguments or
														""
													)
											)
										)
									elseif tc["function"] then
										active_tools[idx].arguments = active_tools[idx].arguments .. tc["function"].arguments
										io.write(colors.yellow(tc["function"].arguments))
									else
										error("unknown tool type: " .. tostring(tc.type))
									end
								end
							elseif choice.finish_reason == "stop" then
								should_run = false
								io.write("\n[Finished]\n")
							elseif choice.finish_reason == "tool_calls" then
								io.write(colors.yellow("\n[Waiting for tools to finish...]\n"))
							-- this is done at the end of the loop
							else
								table.print(choice)
								error("unknown delta content")
							end
						end
					end,
				}
			)

			if #active_tools > 0 then
				local tool_calls = {}

				for _, tc in ipairs(active_tools) do
					table.insert(
						tool_calls,
						{
							id = tc.id,
							type = "function",
							["function"] = {name = tc.name, arguments = tc.arguments},
						}
					)
				end

				self:AddMessage({role = "assistant", content = nil, tool_calls = tool_calls})

				for _, tc in ipairs(active_tools) do
					if tc.type == "function" then
						local args = codec.Decode("json", tc.arguments or "")
						local result = self:ToolCall(tc.name, args)
						self:AddMessage(
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
			else
				while #self.message_queue > 0 do
					local msg = table.remove(self.message_queue, 1)
					self:AddMessage(msg)
					should_run = true
				end
			end

			table.clear(active_tools)
		end

		io.write("\n")
		io.flush()
	end) -- over here!
end

return Agent:Register()