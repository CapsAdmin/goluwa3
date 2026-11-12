local json = import("goluwa/codecs/json.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local MouseInput = import("goluwa/render2d/ui/components/mouse_input.lua")
local objects = import("goluwa/objects/objects.lua")
local mcp = import("addons/mcp/lua/mcp.lua")
local ui_driver = import("addons/mcp/lua/ui_driver.lua")
local SETTLE_FRAMES = 30
local QUERY_SCHEMA = {
	type = "object",
	description = "Finds a shown panel: every given field must match. text is a case insensitive substring unless exact is true. within is a query for an ancestor. index picks the nth match (front most first).",
	properties = {
		id = {type = "number"},
		type = {type = "string"},
		name = {type = "string"},
		text = {type = "string"},
		exact = {type = "boolean"},
		icon = {type = "string"},
		tooltip = {type = "string"},
		editable = {type = "boolean"},
		hint = {type = "string", description = "Substring of a text field's placeholder."},
		row = {
			type = "string",
			description = "Label of a property editor row: the target is that row's value control (checkbox, number, text, vector...).",
		},
		item = {
			type = "string",
			description = "Text of an item drawn by a virtual widget (asset grid tiles, tree table rows) instead of a panel; ui_tree lists them as item lines.",
		},
		index = {type = "number"},
		within = {type = "object"},
	},
}
local POINT_PROPERTIES = {
	target = QUERY_SCHEMA,
	x = {type = "number", description = "Screen x, instead of a target."},
	y = {type = "number", description = "Screen y, instead of a target."},
	dx = {type = "number", description = "Offset from the target's center."},
	dy = {type = "number", description = "Offset from the target's center."},
}

local function resolve_point(args, prefix)
	prefix = prefix or ""
	local target = args[prefix .. "target"]

	if target then
		local offset = Vec2(args[prefix .. "dx"] or 0, args[prefix .. "dy"] or 0)
		local pnl = ui_driver.FindOne(target)
		local center = ui_driver.GetCenter(pnl)

		-- layouts move while content loads: point at the target until it holds still for a frame
		for _ = 1, SETTLE_FRAMES do
			ui_driver.MoveTo(center + offset)
			pnl = ui_driver.FindOne(target)
			local now = ui_driver.GetCenter(pnl)

			if (now - center):GetLength() < 1 then break end

			center = now
		end

		return center + offset, pnl
	end

	local x, y = args[prefix .. "x"], args[prefix .. "y"]
	assert(x and y, "give " .. prefix .. "target or " .. prefix .. "x and " .. prefix .. "y")
	return Vec2(x, y)
end

local function snapshot()
	local shown = {}

	local function walk(pnl)
		for _, child in ipairs(pnl:GetChildren()) do
			if not child.visual or child.visual:GetVisible() then
				if ui_driver.GetScreenRect(child) then shown[child] = true end

				walk(child)
			end
		end
	end

	walk(Panel.World)
	return shown
end

local function report(before, extra)
	ui_driver.WaitFrames(2)
	local lines = {}

	if extra then lines[#lines + 1] = extra end

	local hovered = MouseInput.GetHoveredObject()

	if hovered:IsValid() and hovered ~= Panel.World then
		local info = ui_driver.Describe(hovered)
		lines[#lines + 1] = string.format(
			"hovered: #%d %s %s",
			info.id,
			tostring(info.type),
			info.text and string.format("%q", info.text) or ""
		)
	end

	local focused = objects.GetFocusedObject()

	if focused:IsValid() and focused.transform then
		local info = ui_driver.Describe(focused)
		lines[#lines + 1] = string.format("focused: #%d %s", info.id, tostring(info.type))
	end

	if before then
		local after = snapshot()
		local added, removed = {}, 0

		for pnl in pairs(after) do
			if not before[pnl] and (before[pnl:GetParent()] or not after[pnl:GetParent()]) then
				added[#added + 1] = pnl
			end
		end

		for pnl in pairs(before) do
			if not after[pnl] then removed = removed + 1 end
		end

		if #added > 6 then
			local popups = {}

			for _, pnl in ipairs(added) do
				if
					tostring(pnl.Type):find("window") or
					tostring(pnl.Type):find("menu") or
					tostring(pnl.Type):find("dropdown") or
					pnl:GetParent() == Panel.World
				then
					popups[#popups + 1] = pnl
				end
			end

			lines[#lines + 1] = #added .. " panel subtrees appeared (rebuilt lists), new popups and windows follow"
			added = popups
		end

		if added[1] then
			lines[#lines + 1] = "appeared:"
			local count = 0

			for _, pnl in ipairs(added) do
				local tree = ui_driver.Describe(pnl)
				lines[#lines + 1] = string.format(
					"#%d %s%s%s",
					tree.id,
					tostring(tree.type),
					tree.text and (" " .. string.format("%q", tree.text)) or "",
					tree.rect and
						string.format(" [%d %d %d %d]", tree.rect[1], tree.rect[2], tree.rect[3], tree.rect[4]) or
						""
				)
				lines[#lines + 1] = ui_driver.Tree(pnl, 3):gsub("([^\n]+)", "  %1")
				count = count + 1

				if count >= 6 then break end
			end
		end

		if removed > 0 then lines[#lines + 1] = removed .. " panels disappeared" end
	end

	return table.concat(lines, "\n")
end

local function add(name, description, properties, callback)
	mcp.AddTool(
		name,
		{
			description = description,
			inputSchema = {type = "object", properties = properties or json.createEmptyObject()},
			callback = callback,
		}
	)
end

add(
	"ui_tree",
	"The shown 2D panels as an indented tree: #id type, name, text, icon, tooltip, flags and the screen rect [x y w h]. Use the ids as {id = n} in targets.",
	{
		target = QUERY_SCHEMA,
		depth = {type = "number", description = "How deep to go below the root (default all)."},
	},
	function(args)
		local root = args.target and ui_driver.FindOne(args.target) or Panel.World
		return ui_driver.Tree(root, args.depth)
	end
)

add(
	"ui_find",
	"Shown panels matching a query, front most first, with their rects.",
	{query = QUERY_SCHEMA},
	function(args)
		local lines = {}

		for i, found in ipairs(ui_driver.FindAll(args.query or {})) do
			if i > 30 then
				lines[#lines + 1] = "..."

				break
			end

			if found.IsValid then
				lines[#lines + 1] = json.encode(ui_driver.Describe(found))
			else
				lines[#lines + 1] = string.format("item %q [%d %d %d %d]", tostring(found.text), found.x, found.y, found.w, found.h)
			end
		end

		return lines[1] and table.concat(lines, "\n") or "no match"
	end
)

add(
	"ui_click",
	"Move the mouse to a panel's center (or x, y) and click it like a user would. Reports what is hovered and focused afterwards and the panels that appeared (menus, windows).",
	table.merge(
		{
			button = {
				type = "string",
				description = "button_1 (left, default), button_2 (right), button_3 (middle)",
			},
			count = {type = "number", description = "2 for a double click."},
			modifiers = {
				type = "string",
				description = "Keys held during the click, like \"ctrl\" or \"shift+ctrl\".",
			},
		},
		POINT_PROPERTIES
	),
	function(args)
		local before = snapshot()
		local pos = resolve_point(args)
		local modifiers = args.modifiers and args.modifiers:split("+") or {}

		for _, key in ipairs(modifiers) do
			ui_driver.HoldKey(key, true)
		end

		ui_driver.Click(pos, args.button, args.count)

		for _, key in ipairs(modifiers) do
			ui_driver.HoldKey(key, false)
		end

		return report(before, string.format("clicked at %d %d", pos.x, pos.y))
	end
)

add(
	"ui_move",
	"Move the mouse to a panel's center (or x, y) without clicking (hover, tooltips).",
	POINT_PROPERTIES,
	function(args)
		local before = snapshot()
		local pos = resolve_point(args)
		ui_driver.MoveTo(pos, 2)
		return report(before)
	end
)

add(
	"ui_mouse",
	"Press or release a mouse button where the mouse is, for drags that need several steps.",
	{
		button = {type = "string"},
		press = {type = "boolean"},
	},
	function(args)
		local before = snapshot()

		if args.press then
			ui_driver.Press(args.button or "button_1")
		else
			ui_driver.Release(args.button or "button_1")
		end

		return report(before)
	end
)

add(
	"ui_drag",
	"Press on a point, move to another in steps and release (sliders, gizmo handles, splitters, drag and drop). The points are target/x/y/dx/dy and to_target/to_x/to_y/to_dx/to_dy.",
	table.merge(
		{
			button = {type = "string"},
			steps = {type = "number"},
			to_target = QUERY_SCHEMA,
			to_x = {type = "number"},
			to_y = {type = "number"},
			to_dx = {type = "number"},
			to_dy = {type = "number"},
			modifiers = {type = "string"},
		},
		POINT_PROPERTIES
	),
	function(args)
		local before = snapshot()
		local from = resolve_point(args)
		local to

		if args.to_target or args.to_x then
			to = resolve_point(args, "to_")
		else
			to = from + Vec2(args.to_dx or 0, args.to_dy or 0)
		end

		local modifiers = args.modifiers and args.modifiers:split("+") or {}

		for _, key in ipairs(modifiers) do
			ui_driver.HoldKey(key, true)
		end

		ui_driver.Drag(from, to, args.button, args.steps)

		for _, key in ipairs(modifiers) do
			ui_driver.HoldKey(key, false)
		end

		return report(before, string.format("dragged %d %d -> %d %d", from.x, from.y, to.x, to.y))
	end
)

add(
	"ui_scroll",
	"Scroll the mouse wheel over a point. amount > 0 scrolls up.",
	table.merge({amount = {type = "number"}}, POINT_PROPERTIES),
	function(args)
		local before = snapshot()
		ui_driver.Scroll((resolve_point(args)), args.amount or -1)
		return report(before)
	end
)

add(
	"ui_key",
	"Press and release a key combination such as \"escape\", \"enter\", \"ctrl+z\", \"shift+tab\", \"delete\". With hold = true/false the key stays down or is released (camera movement keys).",
	{
		key = {type = "string"},
		hold = {type = "boolean"},
		seconds = {type = "number", description = "With hold, release after this long."},
	},
	function(args)
		local before = snapshot()

		if args.hold ~= nil then
			ui_driver.HoldKey(args.key, args.hold)

			if args.hold and args.seconds then
				local tasks = import("goluwa/tasks.lua")
				tasks.Wait(args.seconds)
				ui_driver.HoldKey(args.key, false)
			end
		else
			ui_driver.Key(args.key)
		end

		return report(before)
	end
)

add(
	"ui_type",
	"Type text as character input into whatever has keyboard focus (click a text field first, or give a target to click). \\n presses enter.",
	table.merge(
		{
			text = {type = "string"},
			select_all = {
				type = "boolean",
				description = "Press ctrl+a first so the text replaces what is there.",
			},
		},
		POINT_PROPERTIES
	),
	function(args)
		local before = snapshot()

		if args.target or args.x then ui_driver.Click((resolve_point(args))) end

		if args.select_all then ui_driver.Key("ctrl+a") end

		ui_driver.Type(args.text)
		return report(before)
	end
)

add(
	"ui_wait",
	"Let frames pass (animations, async loads).",
	{
		frames = {type = "number"},
		seconds = {type = "number"},
	},
	function(args)
		if args.seconds then import("goluwa/tasks.lua").Wait(args.seconds) end

		ui_driver.WaitFrames(args.frames or 1)
		return "ok"
	end
)
