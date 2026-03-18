local Agent = import("goluwa/llamacpp/agent.lua")
local agent = Agent.New("Qwen3.5-35B-A3B-UD-Q4_K_XL")
agent:AddMessage{
	role = "system",
	content = [[
			If you don't know the answer, use the tools to find it out. 
			Always use the tools when possible, even if you think you already know the answer. 
			Never say that you don't know something, instead say that you will find out using the tools.
		]],
}

local function image(path)
	local fs = import("goluwa/fs.lua")
	local codec = import("goluwa/codec.lua")
	local content = assert(fs.read_file(path))
	return "data:image/jpeg;base64," .. codec.Encode("base64", content)
end

agent:AddMessage{
	role = "user",
	content = {
		{
			type = "text",
			text = "use a subagent to summarize /home/caps/projects/goluwa3/game/addons/test/lua/examples/llamacpp_chat_completion.lua",
		},
	--[[
			{
				type = "image_url",
				image_url = {
					url = image("/home/caps/Pictures/Simmons_idle.jpg"),
				},
			},]]
	},
}
agent:Run() -- will be sent after an assistant message (not right after tool message)
agent:QueueMessage{role = "user", content = "good job"}
