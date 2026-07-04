local T = import("test/environment.lua")
_G.CLIENT = true
_G.SERVER = true
local message = import("goluwa/network/message.lua")

T.Test("Message adds and removes listener", function()
	local called = false

	message.AddListener("test_msg", function(...)
		called = true
	end)

	T(message.listeners["test_msg"])["~="](nil)
	message.RemoveListener("test_msg")
	T(message.listeners["test_msg"])["=="](nil)
end)

T.Test("Message listener receives arguments", function()
	local received_args = {}

	message.AddListener("arg_test", function(...)
		received_args = {...}
	end)

	if message.listeners["arg_test"] then
		message.listeners["arg_test"]("hello", 42, true)
	end

	T(received_args[1])["=="]("hello")
	T(received_args[2])["=="](42)
	T(received_args[3])["=="](true)
	message.RemoveListener("arg_test")
end)

T.Test("Message listener with no arguments", function()
	local called = false

	message.AddListener("no_arg_msg", function(...)
		called = true
	end)

	if message.listeners["no_arg_msg"] then message.listeners["no_arg_msg"]() end

	T(called)["=="](true)
	message.RemoveListener("no_arg_msg")
end)

T.Test("Message listener replaced on re-add", function()
	local count = 0

	message.AddListener("replace_test", function()
		count = count + 1
	end)

	message.AddListener("replace_test", function()
		count = count + 10
	end)

	if message.listeners["replace_test"] then
		message.listeners["replace_test"]()
	end

	-- Second listener should have replaced the first
	T(count)["=="](10)
	message.RemoveListener("replace_test")
end)

T.Test("Message server command registration", function()
	if not SERVER then return end

	local commands = import("goluwa/cli/commands.lua")
	local cmd_called = false
	local cmd_client = nil
	local cmd_args = {}

	commands.AddServerCommand("test_cmd", function(client, ...)
		cmd_called = true
		cmd_client = client
		cmd_args = {...}
	end)

	T(message.server_commands["test_cmd"])["~="](nil)

	-- Simulate receiving a server command via the "scmd" listener
	if message.listeners["scmd"] then
		message.listeners["scmd"]("mock_client", "test_cmd", "arg1", 42)
	end

	T(cmd_called)["=="](true)
	T(cmd_args[1])["=="]("arg1")
	T(cmd_args[2])["=="](42)
	commands.RemoveServerCommand("test_cmd")
	T(message.server_commands["test_cmd"])["=="](nil)
end)

T.Test("Message command client/server separation", function()
	if not SERVER then return end

	local commands = import("goluwa/cli/commands.lua")

	commands.AddServerCommand("sep_test", function(client, ...) -- Server command handler
	end)

	T(message.server_commands["sep_test"])["~="](nil)
	commands.RemoveServerCommand("sep_test")
	T(message.server_commands["sep_test"])["=="](nil)
end)

T.Test("Message broadcast function exists", function()
	T(message.Broadcast)["~="](nil)
	T(type(message.Broadcast))["=="]("function")
end)

T.Test("Message event call functions exist", function()
	if CLIENT then
		-- Client-side message functions
		T(message.Send)["~="](nil)
	end

	if SERVER then
		T(message.Send)["~="](nil)
		T(message.Broadcast)["~="](nil)
	end
end)
