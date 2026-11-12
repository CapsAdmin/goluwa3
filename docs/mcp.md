# MCP: probing a running instance

`addons/mcp` starts an MCP server (JSON-RPC over HTTP, loopback only) in every engine process at startup, client and server alike. The goal is to launch the game normally and probe it from outside while it runs.

- Each process takes the first free port from 8600 and registers `storage/mcp/<pid>_<role>.json` (role `client` or `server`; a `--server-client` process has both, the server is its second lua state). The file is removed on shutdown, `addons/mcp/mcp` also prunes entries whose pid is gone.
- `addons/mcp/mcp list` shows live instances. `addons/mcp/mcp <client|server|port> <tool> ['<json args>']` calls a tool (`lua '<code>'` is short for `run_lua`, `tools` lists them). With several instances of a role the newest wins, pass the port to pick another.
- Tools (`addons/mcp/lua/mcp_tools.lua`, add more with `mcp.AddTool(name, {description, inputSchema, callback})`; return a string, a table, or `{content = {...}, isError = true}`): `run_lua` (a single expression returns its value, statements need `return`; the chunk runs with the plain globals, `import` what you need), `get_logs` (per process ring buffer of the last 4000 lines, `pattern` is a lua pattern), `screenshot` (saves `storage/mcp/screenshot_<role>.png`, errors when headless), `info`.
- Tool calls run in a task between frames: a hung frame or a lost device can not be probed, and a slow `run_lua` stalls the game. `run_lua` can change state, so treat it as read only unless asked.
- Logs come from the `StdOutWrite` event, not `storage/logs/log.txt`, which every process truncates and writes.
- There is no authentication: anything on the machine can run lua in the process. Do not bind it to another address.

## Driving the UI like a user

`addons/mcp/lua/mcp_ui_tools.lua` (2D processes) drives the UI through the window's own input path (`addons/mcp/lua/ui_driver.lua`): the window reports a virtual cursor (`window.ui_driver_position`) and the tools call `OnCursorPosition`, `OnMouseInput`, `OnMouseScroll`, `OnKeyInput` and `OnCharInput` with real frames in between, so hover, focus, menus, drags and key state behave as with a mouse and keyboard. Prefer this over calling widget functions, so input quirks show up.

- `ui_tree` lists shown panels as `#id type name text icon tip hint flags [x y w h]`; `ui_find` returns matches. Targets are queries: `text` (case insensitive substring, exact matches first, `exact`), `type`, `name`, `icon`, `tooltip`, `hint` (a text field's placeholder), `editable`, `id` (from `ui_tree`), `index`, `within` (any query for an ancestor), `row` (a property editor row's label, the target is its value control) and `item` (rows and tiles drawn by virtual widgets: `VirtualGrid` and `TreeTable` report them through `GetDrawnItems()`). Unknown query fields are errors. A match scrolled out of a scroll view is scrolled into view first.
- `ui_click` (`button`, `count` 2 for a double click, `modifiers`), `ui_move`, `ui_drag` (`to_target`/`to_x`/`to_dx`...), `ui_mouse` (press or release), `ui_scroll`, `ui_key` (`"ctrl+z"`, `hold` with `seconds` for camera keys), `ui_type` (`select_all`, `\n` presses enter), `ui_wait`. Each reports what is hovered and focused afterwards and the panels that appeared (menus, windows).
- The console command `ui_steps <file> [delay]` (`addons/mcp/lua/ui_steps.lua`; type it in the console, or put it after the flags: `luajit glw --3d ui_steps tmp/x.steps 0.4`) replays a steps file inside the engine through the same tool callbacks, without MCP, waiting `delay` seconds (0.4) between steps and stopping at the first failure. While it runs, the driver's overlay draws the virtual cursor, a ring on every press and release and the current step at the bottom; the `ui_overlay` tool (`show`, `caption`) turns it on for MCP driven runs.
- `addons/mcp/mcp <role> steps <file>` replays a file of `<tool> <json>` lines. Put such files in `./tmp/`; pin the editor camera with a `run_lua` step before anything that depends on what is under the cursor.
- Property editor numbers need a double click to edit; theme drawing dispatches on `Name`, so identify sliders and similar widgets with a `Tooltip`, not a `Name`.

