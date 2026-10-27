# MCP: probing a running instance

`addons/mcp` starts an MCP server (JSON-RPC over HTTP, loopback only) in every engine process at startup, client and server alike. The goal is to launch the game normally and probe it from outside while it runs.

- Each process takes the first free port from 8600 and registers `storage/mcp/<pid>_<role>.json` (role `client` or `server`; a `--server-client` process has both, the server is its second lua state). The file is removed on shutdown, `addons/mcp/mcp` also prunes entries whose pid is gone.
- `addons/mcp/mcp list` shows live instances. `addons/mcp/mcp <client|server|port> <tool> ['<json args>']` calls a tool (`lua '<code>'` is short for `run_lua`, `tools` lists them). With several instances of a role the newest wins, pass the port to pick another.
- Tools (`addons/mcp/lua/mcp_tools.lua`, add more with `mcp.AddTool(name, {description, inputSchema, callback})`; return a string, a table, or `{content = {...}, isError = true}`): `run_lua` (a single expression returns its value, statements need `return`; the chunk runs with the plain globals, `import` what you need), `get_logs` (per process ring buffer of the last 4000 lines, `pattern` is a lua pattern), `screenshot` (saves `storage/mcp/screenshot_<role>.png`, errors when headless), `info`.
- Tool calls run in a task between frames: a hung frame or a lost device can not be probed, and a slow `run_lua` stalls the game. `run_lua` can change state, so treat it as read only unless asked.
- Logs come from the `StdOutWrite` event, not `storage/logs/log.txt`, which every process truncates and writes.
- There is no authentication: anything on the machine can run lua in the process. Do not bind it to another address.
