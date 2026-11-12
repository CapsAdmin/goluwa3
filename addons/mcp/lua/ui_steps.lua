local json = import("goluwa/codecs/json.lua")
local fs = import("goluwa/filesystem/fs.lua")
local tasks = import("goluwa/tasks.lua")
local commands = import("goluwa/cli/commands.lua")
local mcp = import("addons/mcp/lua/mcp.lua")
local ui_driver = import("addons/mcp/lua/ui_driver.lua")
local ui_steps = {}

-- "<tool> <json arguments>" lines, # comments and blank lines skipped
function ui_steps.Parse(text)
	local steps = {}

	for line in text:gmatch("[^\n]+") do
		local trimmed = line:match("^%s*(.-)%s*$")

		if trimmed ~= "" and not trimmed:starts_with("#") then
			local tool, arguments = trimmed:match("^(%S+)%s*(.*)$")
			steps[#steps + 1] = {
				line = trimmed,
				tool = tool,
				arguments = arguments ~= "" and json.decode(arguments) or {},
			}
		end
	end

	return steps
end

local function first_line(result)
	if type(result) == "table" then
		result = result.content and result.content[1] and result.content[1].text or ""
	end

	return tostring(result):match("^[^\n]*")
end

-- replays a steps file through the same tools MCP calls, with the overlay showing each step, waiting delay seconds
-- between steps; stops at the first step that fails
function ui_steps.Run(path, delay)
	local steps = ui_steps.Parse(assert(fs.read_file(path), "could not read " .. path))

	tasks.CreateTask(
		function()
			for i, step in ipairs(steps) do
				local tool = mcp.tools[step.tool]
				local caption = {string.format("step %d/%d  %s", i, #steps, path), step.line}
				ui_driver.SetOverlay(true, caption)
				local ok, result = xpcall(assert(tool, "unknown tool " .. step.tool).callback, debug.traceback, step.arguments)

				if not ok or type(result) == "table" and result.isError then
					local message = ok and first_line(result) or tostring(result)
					logn("ui_steps: step ", i, " failed: ", step.line, "\n", message)
					caption[3] = "failed: " .. message:match("^[^\n]*")
					return
				end

				logn("ui_steps: ", i, "/", #steps, " ", step.line, " -> ", first_line(result))
				tasks.Wait(delay)
			end

			ui_driver.SetOverlay(true, {string.format("done, %d steps  %s", #steps, path)})
			tasks.Wait(3)
			ui_driver.SetOverlay(false)
		end,
		nil,
		true
	)
end

commands.Add("ui_steps=string,number[0.4]", function(path, delay)
	ui_steps.Run(path, delay)
end)

mcp.AddTool(
	"ui_overlay",
	{
		description = "Draw the driver's cursor, click rings and a caption over the screen so a person can follow what is being done. caption is a list of lines.",
		inputSchema = {
			type = "object",
			properties = {
				show = {type = "boolean"},
				caption = {type = "array", items = {type = "string"}},
			},
		},
		callback = function(args)
			ui_driver.SetOverlay(args.show ~= false, args.caption)
			return "ok"
		end,
	}
)
return ui_steps
