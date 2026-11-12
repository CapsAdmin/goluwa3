local mcp = import("addons/mcp/lua/mcp.lua")
import("addons/mcp/lua/mcp_tools.lua")

if RENDER_2D then
	import("addons/mcp/lua/mcp_ui_tools.lua")
	import("addons/mcp/lua/ui_steps.lua")
end

local port = mcp.StartServer()

if port then llog("%s listening on http://127.0.0.1:%i/mcp", mcp.Role, port) end
