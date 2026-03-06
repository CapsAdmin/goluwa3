local terminal = require("bindings.terminal")
local commands = require("commands")
local repl = require("repl")
local event = require("event")
local sequence_editor = require("sequence_editor")
local system = require("system")
local tui = library()
tui.editor = tui.editor or sequence_editor.New()
tui.last_event = "No events yet"
tui.last_cursor_blink = false
tui.last_input_time = 0
tui.last_click_time = 0
tui.frame_count = 0
tui.click_count = 0
tui.needs_redraw = true
tui.history = tui.history or {}
tui.history_scroll_offset = tui.history_scroll_offset or 0

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

local function get_text_size(text, tab_size)
	local width = 0
	local height = 0

	if not text or text == "" then return 0, 0 end

	for _, line in ipairs(text:split("\n")) do
		height = height + 1
		local _, w = expand_tabs(line, tab_size)

		if w > width then width = w end
	end

	return width, height
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
		local repl_h = math.min(math.max(1, num_lines), math.floor(h / 2))
		local history_h = h - repl_h
		local visible_end = math.min(num_lines, tui.editor.ScrollOffset + repl_h)
		local line_index = visible_end - (h - ev.y)
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
			local num_input_lines = #tui.editor.Buffer:GetLines()
			local repl_h = math.min(math.max(1, num_input_lines), math.floor(h / 2))
			local history_h = h - repl_h

			if ev.y <= history_h then
				local total_history_h = 0

				for i = 1, #tui.history do
					local _, th = get_text_size(tui.history[i], 4)
					total_history_h = total_history_h + th + 2
				end

				local max_scroll = math.max(0, total_history_h - history_h)
				tui.history_scroll_offset = math.min(max_scroll, tui.history_scroll_offset + 1)
			else
				tui.editor:OnMouseWheel(1)
			end
		elseif ev.button == "wheel_down" then
			local num_input_lines = #tui.editor.Buffer:GetLines()
			local repl_h = math.min(math.max(1, num_input_lines), math.floor(h / 2))
			local history_h = h - repl_h

			if ev.y <= history_h then
				tui.history_scroll_offset = math.max(0, tui.history_scroll_offset - 1)
			else
				tui.editor:OnMouseWheel(-1)
			end
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

				if text ~= "" then
					table.insert(tui.history, text)
					logn("TUI Input: " .. text)
				end

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

local function draw_text(term, x, y, text, w, h)
	local line_offset = 0

	for _, line in ipairs(text:split("\n")) do
		local screen_y = y + 1 + line_offset

		if h and line_offset >= h then break end

		local expanded = expand_tabs(line, 4)
		local display_line = " " .. expanded .. " "
		term:SetCaretPosition(x + 1, screen_y)

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
		local screen_y = y + i
		term:SetCaretPosition(x, screen_y)

		if i == 0 or i == rect_h - 1 then
			term:Write("+" .. string.rep("-", rect_w - 2) .. "+")
		else
			term:Write("|" .. string.rep(" ", rect_w - 2) .. "|")
		end
	end

	term:PopAttribute()
	term:PopAttribute()
end

local function draw_scrollbar(term, x, y, h, total_h, scroll_offset)
	if total_h <= h then return end

	local bar_h = math.max(1, math.floor(h * (h / total_h)))
	local max_scroll = total_h - h
	-- Scrollbar position: (offset/max) maps 0..h-bar_h
	local fraction = scroll_offset / max_scroll
	local bar_y = y + math.floor((h - bar_h) * fraction)
	term:PushForegroundColor(100, 100, 100) -- Using grey for visibility
	-- Use absolute positioning to ensure visibility outside viewport logic
	for i = 0, bar_h - 1 do
		term:SetCaretPosition(x, bar_y + i)
		term:Write("▓")
	end

	term:PopAttribute()
end

local function draw_chat_history(term, x, y, w, h)
	term:SetViewport(x, y, w, h)
	-- Pass absolute coordinates for scrollbar drawing
	local total_height = 0
	local box_heights = {}
	local history_count = #tui.history

	for i = 1, history_count do
		local _, th = get_text_size(tui.history[i], 4)
		local rh = th + 2
		box_heights[i] = rh
		total_height = total_height + rh
	end

	draw_scrollbar(term, w, y, h, total_height, total_height - h - tui.history_scroll_offset)
	term:PushForegroundColor(150, 200, 150)
	local current_y = y + h + tui.history_scroll_offset

	for i = history_count, 1, -1 do
		local rect_h = box_heights[i]
		local rect_w = math.min(w - 2, get_text_size(tui.history[i], 4) + 4)
		local rect_y = current_y - rect_h

		if rect_y < y + h and rect_y + rect_h > y then
			draw_decorative_box(term, x, rect_y, rect_w, rect_h)
			draw_text(term, x, rect_y, tui.history[i], rect_w, rect_h - 2)
		end

		current_y = rect_y

		if current_y < y then break end
	end

	term:PopAttribute()
	term:ClearViewport()
end

local function draw_repl(term, x, y, h, time)
	local w = term:GetSize()
	-- REPL Scrollbar (draw before Viewport to ensure it's on the edge of the screen)
	local input_lines = tui.editor.Buffer:GetLines()
	local num_lines = #input_lines
	term:SetViewport(x, y, w, h)
	local blink_time = time - tui.last_input_time
	local cursor_blink = math.floor(blink_time * 2) % 2 == 0
	local cur_line, cur_col = tui.editor:GetCursorLineCol()
	tui.editor:SetViewportHeight(h)
	tui.editor:UpdateViewport()
	local visible_start = tui.editor.ScrollOffset + 1
	local visible_end = math.min(num_lines, tui.editor.ScrollOffset + h)
	term:PushForegroundColor(100, 180, 180)
	local sel_start, sel_stop = tui.editor:GetSelection()
	local current_char_idx = 1

	for i, line in ipairs(input_lines) do
		if i >= visible_start and i <= visible_end then
			local prefix = (i == 1) and "> " or "  "
			local line_offset = visible_end - i
			local screen_y = y + (h - 1) - line_offset
			term:SetCaretPosition(x, screen_y)
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
		else
			current_char_idx = current_char_idx + #line + 1
		end
	end

	draw_scrollbar(term, x + w - 1, y, h, num_lines, tui.editor.ScrollOffset)

	if cursor_blink and cur_line >= visible_start and cur_line <= visible_end then
		local prefix_len = 2
		local line_offset = visible_end - cur_line
		local screen_y = y + (h - 1) - line_offset
		local line_text = input_lines[cur_line]
		local _, cur_vcol = expand_tabs(line_text:sub(1, cur_col - 1))
		term:SetCaretPosition(x + prefix_len + cur_vcol, screen_y)
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

	term:PopAttribute()
	term:ClearViewport()
end

local function draw_debug(term, w, h)
	tui.frame_count = tui.frame_count + 1
	draw_text(term, 1, 1, "frames: " .. tostring(tui.frame_count))

	do
		local text_w, text_h = get_text_size(tui.last_event, 4)
		local rect_w, rect_h = math.min(w - 4, text_w + 4), math.min(h - 4, text_h + 2)
		local x = math.floor((w - rect_w) / 2)
		local y = math.floor((h - rect_h) / 2)
		draw_decorative_box(term, x, y, rect_w, rect_h)
		draw_text(term, x, y, tui.last_event, rect_w, rect_h - 2)
	end
end

function tui.Draw(time)
	local term = repl.GetTerminal()
	local w, h = term:GetSize()
	term:BeginFrame()
	-- Clear current screen instead of full reset to preserve state if needed,
	-- though Clear is generally fine for full redraw.
	term:Clear()
	local input_lines = tui.editor.Buffer:GetLines()
	local repl_h = math.min(math.max(1, #input_lines), math.floor(h / 2))
	local history_h = h - repl_h
	draw_chat_history(term, 1, 1, w, history_h)
	draw_repl(term, 1, history_h + 1, repl_h, time)
	term:EndFrame()

	-- Draw debug overlay last so it stays on top
	if tui.debug_enabled then draw_debug(term, w, h) end

	term:Flush()
end

commands.Add("alt", function()
	repl.SetEnabled(not repl.GetEnabled())
end)

event.AddListener("Update", "tui_demo", function()
	local ok, err = pcall(function()
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

	if not ok then
		repl.SetEnabled(true)
		logn("Error in TUI Update: " .. tostring(err))
	end
end)

return tui