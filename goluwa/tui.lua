local terminal = require("bindings.terminal")
local commands = require("commands")
local repl = require("repl")
local event = require("event")
local sequence_editor = require("sequence_editor")
local system = require("system")
local tui = {}
tui.editor = sequence_editor.New()
tui.last_event = "No events yet"
tui.last_cursor_blink = false
tui.last_input_time = 0
tui.frame_count = 0
tui.click_count = 0
tui.needs_redraw = true

function tui.Invalidate()
	tui.needs_redraw = true
end

local function expand_tabs(s, tab_size)
	tab_size = tab_size or 4
	local res = ""
	local col = 0

	for char in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		if char == "\t" then
			local spaces = tab_size - (col % tab_size)
			res = res .. string.rep(" ", spaces)
			col = col + spaces
		else
			res = res .. char
			col = col + 1
		end
	end

	return res, col
end

function tui.OnEvent(ev, time)
	tui.Invalidate()
	tui.last_input_time = time
	tui.last_event = table.tostring(ev)
	local current_input_text = tui.editor:GetText()
	local current_input_lines = {}

	for line in (current_input_text .. "\n"):gmatch("(.-)\n") do
		table.insert(current_input_lines, line)
	end

	if ev.mouse then
		local term = repl.GetTerminal()
		local w, h = term:GetSize()
		local input_lines = tui.editor.Buffer:GetLines()
		local num_lines = #input_lines
		local max_visible_lines = h - 2
		local visible_end = math.min(num_lines, tui.editor.ScrollOffset + max_visible_lines)
		local screen_y_bottom = h
		local line_index = visible_end - (screen_y_bottom - ev.y)
		local target_vcol = ev.x - 2

		if ev.action == "pressed" and ev.button == "left" then
			if input_lines[line_index] then
				if time - tui.last_click_time < 0.3 then
					tui.click_count = tui.click_count + 1
				else
					tui.click_count = 1
				end

				tui.last_click_time = time
				tui.editor:SetSelectionStart(nil)
				tui.editor:SetVisualLineCol(line_index, target_vcol)

				if tui.click_count == 2 then
					tui.editor:SelectWord()
					tui.is_selecting = false
				elseif tui.click_count >= 3 then
					tui.editor:SelectLine()
					tui.is_selecting = false
				else
					tui.editor:SetSelectionStart(tui.editor:GetCursor())
					tui.is_selecting = true
				end
			end
		elseif ev.action == "released" and ev.button == "left" then
			tui.is_selecting = false

			if tui.editor:GetSelectionStart() == tui.editor:GetCursor() then
				tui.editor:SetSelectionStart(nil)
			end
		elseif ev.action == "moved" and tui.is_selecting then
			if input_lines[line_index] then
				tui.editor:SetVisualLineCol(line_index, target_vcol)
			end
		elseif ev.button == "wheel_up" then
			tui.editor:OnMouseWheel(1)
		elseif ev.button == "wheel_down" then
			tui.editor:OnMouseWheel(-1)
		end
	elseif ev.key then
		tui.editor:SetShiftDown(ev.modifiers and ev.modifiers.shift or false)
		tui.editor:SetControlDown(ev.modifiers and ev.modifiers.ctrl or false)

		if ev.key == "c" and ev.modifiers and ev.modifiers.ctrl then
			repl.SetEnabled(true)
			return true -- handled
		elseif ev.key == "enter" then
			if ev.modifiers and ev.modifiers.alt then
				tui.editor:OnKeyInput("enter")
			else
				local text = tui.editor:GetText()
				logn("TUI Input: " .. text)
				tui.editor:SetText("")
				tui.editor:SetCursor(1)
			end
		elseif #ev.key == 1 and not (ev.modifiers and ev.modifiers.ctrl) then
			tui.editor:OnCharInput(ev.key)
		else
			tui.editor:OnKeyInput(ev.key)
		end
	end
end

local function draw_input_line(term, i, line, h, visible_end, sel_start, sel_stop, current_char_idx, num_lines)
	local prefix = (i == 1) and "> " or "  "
	local screen_y = h - (visible_end - i)
	term:SetCaretPosition(1, screen_y)
	term:Write(prefix)

	if not sel_start then
		local expanded_line = expand_tabs(line)
		term:Write(expanded_line)
		current_char_idx = current_char_idx + #line
	else
		local col = 0

		for j = 1, #line do
			local char = line:sub(j, j)
			local is_selected = current_char_idx >= sel_start and current_char_idx < sel_stop

			if is_selected then
				term:PushBackgroundColor(150, 150, 150)
				term:PushForegroundColor(0, 0, 0)

				if char == "\t" then
					local spaces = 4 - (col % 4)
					term:Write(string.rep(" ", spaces))
					col = col + spaces
				else
					term:Write(char)
					col = col + 1
				end

				term:PopAttribute()
				term:PopAttribute()
			else
				if char == "\t" then
					local spaces = 4 - (col % 4)
					term:Write(string.rep(" ", spaces))
					col = col + spaces
				else
					term:Write(char)
					col = col + 1
				end
			end

			current_char_idx = current_char_idx + 1
		end
	end

	if i < num_lines then
		if sel_start then
			local is_selected = current_char_idx >= sel_start and current_char_idx < sel_stop

			if is_selected then
				term:PushBackgroundColor(150, 150, 150)
				term:Write(" ")
				term:PopAttribute()
			end
		end

		current_char_idx = current_char_idx + 1
	end

	term:ClearLine()
	return current_char_idx
end

local function get_text_size(text, tab_size)
	local width = 0
	local height = 0

	for _, line in ipairs(text:split("\n")) do
		height = height + 1
		local _, w = expand_tabs(line, tab_size)

		if w > width then width = w end
	end

	return width, height
end

local function draw_text(term, x, y, text, w, h)
	local line_offset = 0

	for _, line in ipairs(text:split("\n")) do
		if h and line_offset >= h then break end

		local expanded = expand_tabs(line, 4)
		local display_line = " " .. expanded .. " "
		term:SetCaretPosition(x + 1, y + 1 + line_offset)

		if w then
			term:Write(display_line:sub(1, w - 2))
		else
			term:Write(display_line)
		end

		line_offset = line_offset + 1
	end
end

local function draw_decorative_box(term, x, y, rect_w, rect_h)
	term:PushBackgroundColor(50, 50, 150)
	term:PushForegroundColor(255, 255, 255)

	for i = 0, rect_h - 1 do
		term:SetCaretPosition(x, y + i)

		if i == 0 or i == rect_h - 1 then
			term:Write("+" .. string.rep("-", rect_w - 2) .. "+")
		else
			term:Write("|" .. string.rep(" ", rect_w - 2) .. "|")
		end
	end

	term:PopAttribute()
	term:PopAttribute()
end

local function draw_cursor(term, cursor_blink, cur_line, cur_col, visible_start, visible_end, h, input_lines)
	if cursor_blink and cur_line >= visible_start and cur_line <= visible_end then
		local prefix_len = 2
		local screen_y = h - (visible_end - cur_line)
		local line_text = input_lines[cur_line]
		local _, cur_vcol = expand_tabs(line_text:sub(1, cur_col - 1))
		term:SetCaretPosition(prefix_len + cur_vcol + 1, screen_y)
		term:PushBackgroundColor(255, 255, 255)
		term:PushForegroundColor(0, 0, 0)
		local char = line_text:sub(cur_col, cur_col)

		if char == "" then
			char = " "
		elseif char == "\t" then
			local spaces = 4 - (cur_vcol % 4)
			char = string.rep(" ", spaces)
		end

		term:Write(char)
		term:PopAttribute()
		term:PopAttribute()
	end
end

local function draw_repl(term, h, time)
	local blink_time = time - tui.last_input_time
	local cursor_blink = math.floor(blink_time * 2) % 2 == 0
	local cur_line, cur_col = tui.editor:GetCursorLineCol()
	local input_lines = tui.editor.Buffer:GetLines()
	local num_lines = #input_lines
	local max_visible_lines = h - 2
	tui.editor:SetViewportHeight(max_visible_lines)
	tui.editor:UpdateViewport()
	local visible_start = tui.editor.ScrollOffset + 1
	local visible_end = math.min(num_lines, tui.editor.ScrollOffset + max_visible_lines)
	term:PushForegroundColor(100, 180, 180)
	local sel_start, sel_stop = tui.editor:GetSelection()
	local current_char_idx = 1

	for i, line in ipairs(input_lines) do
		if i >= visible_start and i <= visible_end then
			current_char_idx = draw_input_line(term, i, line, h, visible_end, sel_start, sel_stop, current_char_idx, num_lines)
		else
			current_char_idx = current_char_idx + #line + 1
		end
	end

	draw_cursor(term, cursor_blink, cur_line, cur_col, visible_start, visible_end, h, input_lines)
	term:PopAttribute()
end

function tui.Draw(time)
	local term = repl.GetTerminal()
	local w, h = term:GetSize()
	term:BeginFrame()
	term:Clear()

	do
		tui.frame_count = tui.frame_count + 1
		draw_text(term, 1, 1, "frames: " .. tostring(tui.frame_count))
		draw_repl(term, h, time)

		do
			local text_w, text_h = get_text_size(tui.last_event, 4)
			local rect_w, rect_h = math.min(w - 4, text_w + 4), math.min(h - 4, text_h + 2)
			local x = math.floor((w - rect_w) / 2)
			local y = math.floor((h - rect_h) / 2)
			draw_decorative_box(term, x, y, rect_w, rect_h)
			draw_text(term, x, y, tui.last_event, rect_w, rect_h - 2)
		end
	end

	term:EndFrame()
	term:Flush()
end

commands.Add("alt", function()
	repl.SetEnabled(not repl.GetEnabled())
end)

event.AddListener("Update", "tui_demo", function()
	if repl.GetEnabled() then return end

	local term = repl.GetTerminal()

	if not term then return end

	if not term.mouse_enabled then term:EnableMouse(true) end

	local time = system.GetTime()
	local blink_time = time - tui.last_input_time
	local cursor_blink = math.floor(blink_time * 2) % 2 == 0

	if cursor_blink ~= tui.last_cursor_blink then tui.Invalidate() end

	tui.last_cursor_blink = cursor_blink

	while true do
		local ev = term:ReadEvent()

		if not ev then break end

		if tui.OnEvent(ev, time) then return end
	end

	if not tui.needs_redraw then return end

	tui.needs_redraw = false
	tui.Draw(time)
end)

return tui