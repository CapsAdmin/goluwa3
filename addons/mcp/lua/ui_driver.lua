local Vec2 = import("goluwa/structs/vec2.lua")
local system = import("goluwa/system.lua")
local tasks = import("goluwa/tasks.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local MouseInput = import("goluwa/render2d/ui/components/mouse_input.lua")
local objects = import("goluwa/objects/objects.lua")
local utf8 = import("goluwa/string/utf8.lua")
local json = import("goluwa/codecs/json.lua")
local ui_driver = {}
ui_driver.ids = ui_driver.ids or setmetatable({}, {__mode = "k"})
ui_driver.panels = ui_driver.panels or setmetatable({}, {__mode = "v"})
ui_driver.next_id = ui_driver.next_id or 0

-- the window reports the driver's cursor instead of the real one, the real cursor still sends events
function ui_driver.Attach()
	local window = system.GetWindow()

	if window.ui_driver_attached then return window end

	window.ui_driver_attached = true
	window.ui_driver_position = window:GetMousePosition() and window:GetMousePosition():Copy() or Vec2(0, 0)
	window.GetMousePosition = function(self)
		return self.ui_driver_position
	end
	return window
end

function ui_driver.Detach()
	local window = system.GetWindow()

	if not window.ui_driver_attached then return end

	window.ui_driver_attached = nil
	window.GetMousePosition = nil
end

function ui_driver.WaitFrames(count)
	for _ = 1, count or 1 do
		local frame = system.GetFrameNumber()

		repeat
			tasks.Wait()		
		until system.GetFrameNumber() > frame
	end
end

function ui_driver.GetID(pnl)
	local id = ui_driver.ids[pnl]

	if not id then
		ui_driver.next_id = ui_driver.next_id + 1
		id = ui_driver.next_id
		ui_driver.ids[pnl] = id
		ui_driver.panels[id] = pnl
	end

	return id
end

function ui_driver.GetPanel(id)
	local pnl = ui_driver.panels[tonumber(id)]

	if pnl and pnl:IsValid() then return pnl end
end

function ui_driver.IsShown(pnl)
	local current = pnl

	while current and current:IsValid() and current ~= Panel.World do
		if current.visual and not current.visual:GetVisible() then return false end

		current = current:GetParent()
	end

	return current == Panel.World
end

-- the part of a panel that is on screen (clipped by scroll viewports), nil when none of it is
function ui_driver.GetScreenRect(pnl)
	local transform = pnl.transform

	if not transform then return end

	local x1, y1, x2, y2 = transform:GetVisibleLocalRect(0, 0, transform.Size.x, transform.Size.y)

	if not x1 then return end

	local a = transform:LocalToGlobal(Vec2(x1, y1))
	local b = transform:LocalToGlobal(Vec2(x2, y2))
	local size = Panel.World.transform:GetSize()
	local left, top = math.max(math.min(a.x, b.x), 0), math.max(math.min(a.y, b.y), 0)
	local right, bottom = math.min(math.max(a.x, b.x), size.x), math.min(math.max(a.y, b.y), size.y)

	if right - left < 1 or bottom - top < 1 then return end

	return left, top, right, bottom
end

function ui_driver.GetText(pnl)
	if pnl.text and pnl.text.GetText then
		local text = pnl.text:GetText()

		if text ~= "" then return text end
	end

	for _, key in ipairs{"Text", "Title", "Label"} do
		local value = rawget(pnl, key)

		if type(value) == "string" and value ~= "" then return value end
	end
end

function ui_driver.Describe(pnl)
	local x1, y1, x2, y2 = ui_driver.GetScreenRect(pnl)
	local info = {
		id = ui_driver.GetID(pnl),
		type = pnl.Type,
		name = pnl.Name ~= pnl.Type and pnl.Name ~= "" and pnl.Name or nil,
		text = ui_driver.GetText(pnl),
		tooltip = type(rawget(pnl, "Tooltip")) == "string" and pnl.Tooltip or nil,
		icon = type(rawget(pnl, "Icon")) == "string" and pnl.Icon or nil,
	}

	if x1 then
		info.rect = {math.floor(x1), math.floor(y1), math.floor(x2 - x1), math.floor(y2 - y1)}
	end

	if ui_driver.IsEditable(pnl) then info.editable = true end

	if type(rawget(pnl, "Hint")) == "string" and pnl.Hint ~= "" then
		info.hint = pnl.Hint
	end

	if objects.GetFocusedObject() == pnl then info.focused = true end

	if pnl.Disabled then info.disabled = true end

	if pnl.Active then info.active = true end

	return info
end

function ui_driver.IsEditable(pnl)
	return pnl.Type == "panel_text_edit" or
		pnl.text and
		pnl.text.GetEditable and
		pnl.text:GetEditable() and
		pnl:GetParent().Type ~= "panel_text_edit"
end

local QUERY_KEYS = {
	id = true,
	type = true,
	name = true,
	text = true,
	exact = true,
	icon = true,
	tooltip = true,
	editable = true,
	hint = true,
	within = true,
	hidden = true,
	clipped = true,
	index = true,
	row = true,
	item = true,
}

local function matches(pnl, query)
	if query.id then return ui_driver.GetID(pnl) == tonumber(query.id) end

	if query.type and pnl.Type ~= query.type then return false end

	if query.name and pnl.Name ~= query.name then return false end

	if query.icon and rawget(pnl, "Icon") ~= query.icon then return false end

	if query.tooltip then
		local tooltip = rawget(pnl, "Tooltip")

		if
			type(tooltip) ~= "string" or
			not tooltip:lower():find(query.tooltip:lower(), 1, true)
		then
			return false
		end
	end

	if query.text then
		local text = ui_driver.GetText(pnl)

		if not text then return false end

		if query.exact then
			if text ~= query.text then return false end
		elseif not text:lower():find(query.text:lower(), 1, true) then
			return false
		end
	end

	if query.editable and not ui_driver.IsEditable(pnl) then return false end

	if query.hint then
		local hint = rawget(pnl, "Hint")

		if type(hint) ~= "string" or not hint:lower():find(query.hint:lower(), 1, true) then
			return false
		end
	end

	return true
end

-- query: {id, type, name, text, exact, icon, tooltip, editable, within (a query for an ancestor), hidden}
-- shown panels only unless hidden is true, front most (drawn last) first
function ui_driver.Find(query, root)
	for key in pairs(query) do
		if not QUERY_KEYS[key] then error("unknown query field " .. tostring(key), 2) end
	end

	local results = {}
	root = root or Panel.World

	if query.within then
		local scopes = ui_driver.FindAll(query.within)

		if not scopes[1] then return results end

		root = scopes[1]
	end

	local function walk(pnl)
		local children = pnl:GetChildren()

		for i = #children, 1, -1 do
			local child = children[i]

			if query.hidden or not child.visual or child.visual:GetVisible() then
				walk(child)

				if
					matches(child, query) and
					(
						query.hidden or
						query.clipped or
						ui_driver.GetScreenRect(child)
					)
				then
					results[#results + 1] = child
				end
			end
		end
	end

	walk(root)

	if query.text and not query.exact then
		local lower = query.text:lower()
		local exact = {}

		for _, pnl in ipairs(results) do
			if ui_driver.GetText(pnl):lower() == lower then exact[#exact + 1] = pnl end
		end

		for _, pnl in ipairs(results) do
			if ui_driver.GetText(pnl):lower() ~= lower then exact[#exact + 1] = pnl end
		end

		results = exact
	end

	return results
end

-- items drawn by virtual widgets (grids, tree tables) that are not panels, matched by query.item
function ui_driver.FindItems(query)
	local scopes = query.within and ui_driver.FindAll(query.within) or {Panel.World}
	local wanted = query.item:lower()
	local exact, partial = {}, {}

	local function walk(pnl)
		for _, child in ipairs(pnl:GetChildren()) do
			if not child.visual or child.visual:GetVisible() then
				if child.GetDrawnItems then
					for _, item in ipairs(child:GetDrawnItems()) do
						local text = item.text and tostring(item.text):lower()

						if text == wanted then
							exact[#exact + 1] = item
						elseif text and not query.exact and text:find(wanted, 1, true) then
							partial[#partial + 1] = item
						end
					end
				end

				walk(child)
			end
		end
	end

	if scopes[1] then walk(scopes[1]) end

	for _, item in ipairs(partial) do
		exact[#exact + 1] = item
	end

	return exact
end

-- the value control of a property editor row, by the row's label
function ui_driver.FindPropertyControl(query)
	local labels = ui_driver.Find{
		type = "panel_text",
		text = query.row,
		exact = true,
		within = query.within,
		clipped = query.clipped,
	}
	local found = {}

	for _, label in ipairs(labels) do
		local label_row = label:GetParent()

		if label_row.Name == "property_label_row" then
			local _, top, _, bottom = label_row.transform:GetWorldRectFast()
			local split = label_row:GetParent():GetParent()

			for _, row in ipairs(ui_driver.Find({name = "property_editor_row", clipped = true}, split)) do
				local _, y1, _, y2 = row.transform:GetWorldRectFast()

				if math.abs(y1 - top) < 2 and math.abs(y2 - bottom) < 2 then
					found[#found + 1] = row:GetChildren()[1] or row
				end
			end
		end
	end

	return found
end

function ui_driver.FindAll(query)
	if query.row then return ui_driver.FindPropertyControl(query) end

	if query.item then return ui_driver.FindItems(query) end

	return ui_driver.Find(query)
end

-- a match that is scrolled out of view is scrolled into view first, like a user would
function ui_driver.FindOne(query)
	local found = ui_driver.FindAll(query)

	if not found[1] and not query.item then
		local clipped = ui_driver.FindAll(table.merge(table.copy(query), {clipped = true}))
		local target = clipped[query.index or 1]
		local scroll = target and target:GetParent()

		while scroll and scroll:IsValid() and scroll.Type ~= "panel_scrollable_panel" do
			scroll = scroll:GetParent()
		end

		if scroll and scroll:IsValid() then
			scroll:ScrollChildIntoView(target)
			ui_driver.WaitFrames(2)
			found = ui_driver.FindAll(query)
		end
	end

	if not found[1] then error("nothing matches " .. json.encode(query), 0) end

	return found[query.index or
		1] or
		error("only " .. #found .. " match " .. json.encode(query), 0)
end

function ui_driver.Tree(root, max_depth, include_empty)
	local lines = {}
	max_depth = max_depth or 64

	local function walk(pnl, depth)
		for _, child in ipairs(pnl:GetChildren()) do
			if (not child.visual or child.visual:GetVisible()) and child.transform then
				local x1 = ui_driver.GetScreenRect(child)
				local redundant = child:GetChildren()[1] == nil and
					(
						child.Type == "panel_text" and
						ui_driver.GetText(child) == ui_driver.GetText(pnl)
						or
						child.Type == "panel_icon" and
						rawget(child, "Icon") == rawget(pnl, "Icon")
					)

				if (x1 or include_empty) and not redundant then
					local info = ui_driver.Describe(child)
					local parts = {string.rep("  ", depth), "#", info.id, " ", tostring(info.type)}

					if info.name then parts[#parts + 1] = " name=" .. info.name end

					if info.text then
						parts[#parts + 1] = " text=" .. string.format("%q", info.text:sub(1, 60))
					end

					if info.icon then parts[#parts + 1] = " icon=" .. info.icon end

					if info.tooltip then
						parts[#parts + 1] = " tip=" .. string.format("%q", info.tooltip)
					end

					if info.hint then
						parts[#parts + 1] = " hint=" .. string.format("%q", info.hint)
					end

					if info.editable then parts[#parts + 1] = " editable" end

					if info.focused then parts[#parts + 1] = " focused" end

					if info.disabled then parts[#parts + 1] = " disabled" end

					if info.active then parts[#parts + 1] = " active" end

					if info.rect then
						parts[#parts + 1] = string.format(" [%d %d %d %d]", info.rect[1], info.rect[2], info.rect[3], info.rect[4])
					end

					lines[#lines + 1] = table.concat(parts)

					if child.GetDrawnItems then
						for i, item in ipairs(child:GetDrawnItems()) do
							if i > 60 then
								lines[#lines + 1] = string.rep("  ", depth + 1) .. "..."

								break
							end

							lines[#lines + 1] = string.format(
								"%sitem %q [%d %d %d %d]",
								string.rep("  ", depth + 1),
								tostring(item.text),
								item.x,
								item.y,
								item.w,
								item.h
							)
						end
					end

					if depth < max_depth then walk(child, depth + 1) end
				end
			end
		end
	end

	walk(root or Panel.World, 0)
	return table.concat(lines, "\n")
end

function ui_driver.GetCenter(pnl)
	if not pnl.IsValid then
		return Vec2(math.floor(pnl.x + pnl.w / 2), math.floor(pnl.y + math.min(pnl.h / 2, 12)))
	end

	local x1, y1, x2, y2 = ui_driver.GetScreenRect(pnl)

	if not x1 then error(tostring(pnl) .. " is not on screen", 2) end

	return Vec2(math.floor((x1 + x2) / 2), math.floor((y1 + y2) / 2))
end

function ui_driver.MoveTo(pos, steps)
	local window = ui_driver.Attach()
	local from = window.ui_driver_position:Copy()
	steps = steps or 1

	for i = 1, steps do
		local next_pos = from + (pos - from) * (i / steps)
		window:SetMouseDelta(window:GetMouseDelta() + (next_pos - window.ui_driver_position))
		window.ui_driver_position = next_pos
		window:OnCursorPosition(next_pos:Copy())
		ui_driver.WaitFrames(1)
	end
end

function ui_driver.Press(button)
	local window = ui_driver.Attach()
	ui_driver.AddPulse(window.ui_driver_position, true)
	window:OnMouseInput(button, true)
end

function ui_driver.Release(button)
	local window = ui_driver.Attach()
	ui_driver.AddPulse(window.ui_driver_position, false)
	window:OnMouseInput(button, false)
end

-- a cursor, click rings and a caption drawn over everything while the overlay is on, so a replay can be watched
do
	local event = import("goluwa/event.lua")
	local render2d = import("goluwa/render2d/render2d.lua")
	local debug_draw = import("goluwa/debug_draw.lua")
	local PULSE_TIME = 0.45
	local PULSE_RADIUS = 26
	local RING_SEGMENTS = 24
	local ARROW = {
		Vec2(0, 0),
		Vec2(0, 20),
		Vec2(5, 15),
		Vec2(9, 23),
		Vec2(12, 21),
		Vec2(8, 14),
		Vec2(15, 14),
	}
	local overlay = {enabled = false, caption = nil, pulses = {}, down = false}
	ui_driver.overlay = overlay

	function ui_driver.SetOverlay(enabled, caption)
		overlay.enabled = enabled
		overlay.caption = caption
	end

	function ui_driver.AddPulse(position, press)
		overlay.down = press
		overlay.pulses[#overlay.pulses + 1] = {
			position = position:Copy(),
			time = system.GetUnscaledElapsedTime(),
			press = press,
		}
	end

	local function line(a, b, width)
		local dx, dy = b.x - a.x, b.y - a.y
		render2d.DrawRectf(a.x, a.y, math.sqrt(dx * dx + dy * dy), width, math.atan2(dy, dx), 0, width / 2)
	end

	local function ring(center, radius, width)
		for i = 0, RING_SEGMENTS - 1 do
			local a = i / RING_SEGMENTS * math.pi * 2
			local b = (i + 1) / RING_SEGMENTS * math.pi * 2
			line(
				Vec2(center.x + math.cos(a) * radius, center.y + math.sin(a) * radius),
				Vec2(center.x + math.cos(b) * radius, center.y + math.sin(b) * radius),
				width
			)
		end
	end

	local function arrow(position, width)
		for i = 1, #ARROW do
			line(position + ARROW[i], position + ARROW[i % #ARROW + 1], width)
		end
	end

	event.AddListener(
		"Draw2D",
		"ui_driver_overlay",
		function()
			if not overlay.enabled then return end

			local window = system.GetWindow()
			local position = window.ui_driver_attached and window.ui_driver_position
			local now = system.GetUnscaledElapsedTime()
			render2d.SetTexture(nil)

			for i = #overlay.pulses, 1, -1 do
				local pulse = overlay.pulses[i]
				local t = (now - pulse.time) / PULSE_TIME

				if t >= 1 then
					table.remove(overlay.pulses, i)
				else
					render2d.SetColor(1, pulse.press and 0.75 or 1, 0.2, 1 - t)
					ring(pulse.position, PULSE_RADIUS * (pulse.press and t or 1 - t * 0.5), 3)
				end
			end

			if position then
				render2d.SetColor(0, 0, 0, 0.9)
				arrow(position, 4)
				render2d.SetColor(1, 1, 1, 1)
				arrow(position, 2)

				if overlay.down then
					render2d.SetColor(1, 0.75, 0.2, 0.9)
					render2d.DrawRect(position.x - 4, position.y - 4, 8, 8)
				end
			end

			if overlay.caption then
				local width = render2d.GetSize()
				debug_draw.DrawTextBlock(
					overlay.caption,
					width / 2 - 200,
					math.huge,
					{background_alpha = 0.8, line_gap = 8, padding = 10}
				)
			end
		end,
		{priority = -1000}
	)
end

function ui_driver.Click(pos, button, count)
	button = button or "button_1"
	ui_driver.MoveTo(pos)

	for _ = 1, count or 1 do
		ui_driver.Press(button)
		ui_driver.WaitFrames(1)
		ui_driver.Release(button)
		ui_driver.WaitFrames(1)
	end

	return MouseInput.GetHoveredObject()
end

function ui_driver.Drag(from, to, button, steps)
	button = button or "button_1"
	ui_driver.MoveTo(from)
	ui_driver.Press(button)
	ui_driver.WaitFrames(1)
	ui_driver.MoveTo(to, steps or 8)
	ui_driver.Release(button)
	ui_driver.WaitFrames(1)
end

function ui_driver.Scroll(pos, amount)
	local window = ui_driver.Attach()
	ui_driver.MoveTo(pos)
	window:OnMouseScroll(Vec2(0, amount))
	ui_driver.WaitFrames(2)
end

local MODIFIERS = {
	ctrl = "left_control",
	control = "left_control",
	shift = "left_shift",
	alt = "left_alt",
}

-- "ctrl+s", "escape", "shift+tab"
function ui_driver.Key(combo)
	local window = ui_driver.Attach()
	local keys = combo:split("+")
	local key = table.remove(keys)

	for _, modifier in ipairs(keys) do
		window:OnKeyInput(MODIFIERS[modifier] or modifier, true)
	end

	window:OnKeyInput(key, true)
	ui_driver.WaitFrames(1)
	window:OnKeyInput(key, false)

	for i = #keys, 1, -1 do
		window:OnKeyInput(MODIFIERS[keys[i]] or keys[i], false)
	end

	ui_driver.WaitFrames(1)
end

function ui_driver.HoldKey(key, press)
	ui_driver.Attach():OnKeyInput(MODIFIERS[key] or key, press)
end

local CHAR_KEYS = {[" "] = "space", ["\n"] = "enter", ["\t"] = "tab"}

function ui_driver.Type(text)
	local window = ui_driver.Attach()

	for _, char in ipairs(utf8.to_list(text)) do
		local key = CHAR_KEYS[char] or char:lower()

		if char ~= "\n" then window:OnCharInput(char) end

		window:OnKeyInput(key, true)
		window:OnKeyInput(key, false)
	end

	ui_driver.WaitFrames(1)
end

return ui_driver
