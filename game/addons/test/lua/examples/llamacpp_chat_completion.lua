local Agent = require("llamacpp.agent")
local agent = Agent.New("Qwen3.5-35B-A3B-UD-Q4_K_XL_2")
agent:AddMessage(
	{
		role = "system",
		content = [[
If you don't know the answer, use the tools to find it out. 
Always use the tools when possible, even if you think you already know the answer. 
Never say that you don't know something, instead say that you will find out using the tools.
]],
	}
)
agent:AddMessage({role = "user", content = "find all instances of TODO in lua files"})
agent:Run()
agent:QueueMessage({role = "user", content = "good job"}) -- will be sent after an assistant message (not right after tool message)