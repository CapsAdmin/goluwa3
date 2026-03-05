HOTRELOAD = false
local http = require("http")
local llamacpp = require("llamacpp.api")
local codec = require("codec")
local colors = require("helpers.colors")
local tools = require("llamacpp.tools")
local prototype = require("prototype")
local tasks = require("tasks")
local Agent = prototype.CreateTemplate("llamacpp_agent")
tools.sub_agent = {
	description = [[
		creates a new sub-agent with its own model and system prompt. 
		Use this to delegate tasks to specialized agents or to break down complex problems into simpler steps.
	]],
	parameters = {
		type = "object",
		properties = {
			system_prompt = {type = "string", description = "the system prompt for the sub-agent"},
			message = {type = "string", description = "the initial message to send to the sub-agent"},
		},
		required = {"system_prompt", "message"},
	},
	func = function(args, agent)
		if agent.is_sub_agent then
			return "error: sub-agents are not allowed to create their own sub-agents"
		end

		local sub_agent = Agent.New(agent:GetModel())
		sub_agent:AddMessage({role = "system", content = args.system_prompt})
		sub_agent:AddMessage({role = "user", content = args.message})
		sub_agent.is_sub_agent = true
		tasks.WaitForNestedTask(sub_agent:Run())
		return "sub-agent finished"
	end,
}
Agent:GetSet("Tools", tools)
Agent:GetSet("Messages")
Agent:GetSet("Model", "Qwen3.5-35B-A3B-UD-Q4_K_XL")

function Agent.New(model)
	local self = Agent:CreateObject(
		{
			Tools = {},
			Messages = {},
			Model = model or Agent.Model,
			message_queue = {},
			active_tools = {},
			current_content = "",
			in_reasoning = false,
			slots = {},
		}
	)
	self.slots = {}
	return self
end

function Agent:OnLogEvent(event)
	if event.type == "role" then
		io.write(event.role .. ":\n")
	elseif event.type == "message_content" then
		io.write(event.content .. "\n")
	elseif event.type == "message_tool_calls" then
		for _, tc in ipairs(event.tool_calls) do
			io.write(
				colors.yellow(
					"[Tool call message: " .. tc["function"].name .. " with arguments: " .. (
							tc["function"].arguments or
							""
						) .. "]\n"
				)
			)
		end
	elseif event.type == "content_token" then
		io.write(event.content)
	elseif event.type == "reasoning_token" then
		io.write(colors.dim(event.content))
	elseif event.type == "reasoning_end" then
		io.write("\n")
	elseif event.type == "message_separator" then
		io.write("\n----------------\n")
	elseif event.type == "tool_call_start" then
		io.write(
			colors.yellow("\n[Tool call start: " .. event.name .. " with arguments: " .. event.args)
		)
	elseif event.type == "tool_call_arg_fragment" then
		io.write(colors.yellow(event.fragment))
	elseif event.type == "tool_execute" then
		io.write(colors.yellow("tool-" .. event.name .. ":" .. event.args .. "\n"))
	elseif event.type == "tool_result" then
		io.write(colors.yellow("<< " .. event.result .. "\n"))
	elseif event.type == "tool_error" then
		io.write(colors.red("<< " .. event.error .. "\n"))
	elseif event.type == "tool_waiting" then
		io.write(colors.yellow("\n[Waiting for tools to finish...]\n"))
	elseif event.type == "finished" then
		io.write("\n[Finished]\n")
	elseif event.type == "truncated" then
		io.write(colors.red("\n[Warning: response truncated due to max_tokens limit]\n"))
	elseif event.type == "run_end" then
		io.write("\n")
	end

	io.flush()
end

function Agent:AddMessage(msg, silent)
	if not silent then
		if #self.Messages > 0 then self:OnLogEvent({type = "message_separator"}) end

		self:OnLogEvent({type = "role", role = tostring(msg.role)})

		if msg.content then
			self:OnLogEvent({type = "message_content", content = tostring(msg.content)})
		end

		if msg.tool_calls then
			self:OnLogEvent({type = "message_tool_calls", tool_calls = msg.tool_calls})
		end
	end

	table.insert(self.Messages, msg)
end

function Agent:QueueMessage(msg)
	table.insert(self.message_queue, msg)
end

function Agent:ToolCall(name, json_args)
	local ok, args = pcall(codec.Decode, "json", json_args)

	if not ok then return "invalid JSON arguments: " .. tostring(args) end

	local tools = self:GetTools()

	if not tools[name] then return "unknown tool: " .. tostring(name) end

	for _, v in pairs(tools[name].parameters.required) do
		if args[v] == nil then return "missing required argument: " .. v end
	end

	local ok, res = pcall(tools[name].func, args, self)

	do
		local display_args = name == "lua" and args.lua_code or table.tostring(args)
		self:OnLogEvent({type = "tool_execute", name = name, args = display_args})
	end

	if not ok then
		self:OnLogEvent({type = "tool_error", error = tostring(res)})
		return "error: " .. tostring(res)
	end

	res = table.tostring(res)
	self:OnLogEvent({type = "tool_result", result = res})
	return res
end

function Agent:OnChoice(choice)
	if choice.delta.role then
		if self.in_reasoning then
			self:OnLogEvent({type = "reasoning_end"})
			self.in_reasoning = false
		end

		if #self.Messages > 0 then self:OnLogEvent({type = "message_separator"}) end

		self:OnLogEvent({type = "role", role = tostring(choice.delta.role)})
	elseif choice.delta.content then
		if self.in_reasoning then
			self:OnLogEvent({type = "reasoning_end"})
			self.in_reasoning = false
		end

		local content = tostring(choice.delta.content)
		self.current_content = self.current_content .. content
		self:OnLogEvent({type = "content_token", content = content})
	elseif choice.delta.reasoning_content then
		self.in_reasoning = true
		self:OnLogEvent({type = "reasoning_token", content = tostring(choice.delta.reasoning_content)})
	elseif choice.delta.tool_calls then
		if self.in_reasoning then
			self:OnLogEvent({type = "reasoning_end"})
			self.in_reasoning = false
		end

		for _, tc in ipairs(choice.delta.tool_calls) do
			local idx = (tc.index or 0) + 1
			local slot = self.slots[idx]

			if tc.id then
				-- If a slot already existed, it was for the same index but without an ID (hallucinated delta?)
				-- or it's a completely new index with an ID.
				slot = {
					id = tc.id,
					name = tc["function"].name,
					type = "function",
					arguments = tc["function"].arguments or "",
				}
				self.slots[idx] = slot
				self:OnLogEvent(
					{
						type = "tool_call_start",
						name = tc["function"].name,
						args = tc["function"].arguments or "",
					}
				)
			elseif tc["function"] then
				-- If we don't have a slot for this index yet, create a skeleton
				if not slot then
					slot = {
						id = "unknown",
						name = tc["function"].name or "unknown",
						type = "function",
						arguments = "",
					}
					self.slots[idx] = slot
				end

				if tc["function"].name then slot.name = tc["function"].name end

				if tc["function"].arguments then
					slot.arguments = (slot.arguments or "") .. tc["function"].arguments
					self:OnLogEvent({type = "tool_call_arg_fragment", fragment = tc["function"].arguments})
				end
			end
		end
	end

	if choice.finish_reason == "tool_calls" then
		self:OnLogEvent({type = "tool_waiting"})
		-- Convert slots map to a flat list for execution
		local active_tools = {}

		for _, slot in pairs(self.slots) do
			table.insert(active_tools, slot)
		end

		if #active_tools == 0 then
			error("no active tools found in slots, but finish reason is tool_calls")
		end

		self.current_content = ""
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

		self:AddMessage({role = "assistant", tool_calls = tool_calls}, true)

		for _, tc in ipairs(active_tools) do
			if tc.type == "function" then
				llog("[DEBUG] Executing tool %s with arguments: %q", tc.name, tc.arguments)
				local result = self:ToolCall(tc.name, tc.arguments)
				self:AddMessage(
					{
						role = "tool",
						tool_call_id = tc.id,
						content = result,
					},
					true
				)
			else
				error("unknown tool type: " .. tostring(tc.type))
			end
		end

		table.clear(self.slots)
	elseif choice.finish_reason == "stop" then
		table.clear(self.slots)

		if self.current_content ~= "" then
			self:AddMessage({role = "assistant", content = self.current_content}, true)
			self.current_content = ""
		end

		if self.message_queue[1] then
			while #self.message_queue > 0 do
				local msg = table.remove(self.message_queue, 1)
				self:AddMessage(msg)
				self.should_run = true
			end
		else
			self.should_run = false
			self:OnLogEvent({type = "finished"})
		end
	elseif choice.finish_reason == "length" then
		-- fix: handle max_tokens truncation gracefully
		self:OnLogEvent({type = "truncated"})
		table.clear(self.active_tools)

		if self.current_content ~= "" then
			self:AddMessage({role = "assistant", content = self.current_content})
			self.current_content = ""
		end

		self.should_run = false
	end
end

function Agent:GetToolDescriptions()
	local tbl = {}

	for k, v in pairs(self:GetTools()) do
		table.insert(
			tbl,
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

	return tbl
end

function Agent:RunAsync()
	self.should_run = true

	while self.should_run do
		llamacpp.ChatCompletion(
			{
				model = self:GetModel(),
				temperature = 0.6,
				top_p = 0.95,
				top_k = 20,
				min_p = 0.0,
				--
				messages = self:GetMessages(),
				tools = self:GetToolDescriptions(),
				on_data = function(data)
					for _, choice in ipairs(data.choices) do
						self:OnChoice(choice)
					end
				end,
			}
		)
	end

	self:OnLogEvent({type = "run_end"})
end

function Agent:Run()
	return tasks.CreateTask(function()
		self:RunAsync()
	end)
end

return Agent:Register()