local commands = import("goluwa/cli/commands.lua")
local mcp = import("addons/llamacpp/lua/mcp.lua")

commands.Add("start_mcp_server=number[8600]", function(port)
	mcp.StartServer(tonumber(port) or 8600)
end)
