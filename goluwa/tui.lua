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
tui.scroll_offset = 0
tui.frame_count = 0

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
	local needs_redraw = cursor_blink ~= tui.last_cursor_blink
	tui.last_cursor_blink = cursor_blink

	while true do
		local ev = term:ReadEvent()

		if not ev then break end

		tui.last_event = table.tostring(ev)
		needs_redraw = true
		tui.last_input_time = time
		cursor_blink = true
		-- We need input_lines for mouse hit testing
		local current_input_text = tui.editor:GetText()
		local current_input_lines = {}

		for line in (current_input_text .. "\n"):gmatch("(.-)\n") do
			table.insert(current_input_lines, line)
		end

		if ev.mouse then
			local w, h = term:GetSize()
			local num_lines = #current_input_lines
			local max_visible_lines = h - 2
			local visible_end = math.min(num_lines, tui.scroll_offset + max_visible_lines)
			-- Convert screen y to relative line index
			local screen_y_bottom = h -- index of the last visible line
			local line_index = visible_end - (screen_y_bottom - ev.y)
			local target_vcol = ev.x - 2 -- prefix_len is 2
			if ev.action == "pressed" and ev.button == "left" then
				if current_input_lines[line_index] then
					tui.editor:SetSelectionStart(nil) -- Clear current selection
					tui.editor:SetVisualLineCol(line_index, target_vcol)
					tui.editor:SetSelectionStart(tui.editor:GetCursor())
					tui.is_selecting = true
				end
			elseif ev.action == "released" and ev.button == "left" then
				tui.is_selecting = false

				if tui.editor:GetSelectionStart() == tui.editor:GetCursor() then
					tui.editor:SetSelectionStart(nil)
				end
			elseif ev.action == "moved" and tui.is_selecting then
				if current_input_lines[line_index] then
					tui.editor:SetVisualLineCol(line_index, target_vcol)
				end
			elseif ev.button == "wheel_up" then
				tui.scroll_offset = math.max(0, tui.scroll_offset - 1)
				tui.user_scrolled = true
			elseif ev.button == "wheel_down" then
				local num_lines = #current_input_lines
				tui.scroll_offset = math.min(math.max(0, num_lines - max_visible_lines), tui.scroll_offset + 1)
				tui.user_scrolled = true
			end
		elseif ev.key then
			tui.user_scrolled = false
			tui.editor:SetShiftDown(ev.modifiers and ev.modifiers.shift or false)
			tui.editor:SetControlDown(ev.modifiers and ev.modifiers.ctrl or false)

			if ev.key == "c" and ev.modifiers and ev.modifiers.ctrl then
				repl.SetEnabled(true)
				return
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

	if not needs_redraw then return end

	local input_text = tui.editor:GetText()
	local input_lines = {}

	for line in (input_text .. "\n"):gmatch("(.-)\n") do
		table.insert(input_lines, line)
	end

	local w, h = term:GetSize()
	local rect_w, rect_h = 20, 10
	local x = math.floor((w - rect_w) / 2)
	local y = math.floor((h - rect_h) / 2)
	term:BeginFrame()
	term:Clear()
	tui.frame_count = tui.frame_count + 1
	term:SetCaretPosition(1, 1)
	term:Write("Frames: " .. tui.frame_count)
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

	-- Draw title
	local debug_text = " LAST EVENT: " .. tui.last_event .. " "
	term:SetCaretPosition(x + math.floor((rect_w - #debug_text) / 2), y + math.floor(rect_h / 2))
	term:Write(debug_text)
	term:PopAttribute()
	term:PopAttribute()
	-- Draw input area at bottom
	local num_lines = #input_lines
	local max_visible_lines = h - 2 -- Leave some space at the top
	local cur_line, cur_col = tui.editor:GetCursorLineCol()

	-- Handle scrolling: ensure cursor is within [scroll_offset + 1, scroll_offset + max_visible_lines]
	if not tui.user_scrolled then
		if cur_line <= tui.scroll_offset then
			tui.scroll_offset = cur_line - 1
		elseif cur_line > tui.scroll_offset + max_visible_lines then
			tui.scroll_offset = cur_line - max_visible_lines
		end
	end

	-- Clamp scroll offset to valid range
	tui.scroll_offset = math.max(0, math.min(tui.scroll_offset, math.max(0, num_lines - max_visible_lines)))
	local visible_start = tui.scroll_offset + 1
	local visible_end = math.min(num_lines, tui.scroll_offset + max_visible_lines)
	term:PushForegroundColor(100, 180, 180)
	local sel_start, sel_stop = tui.editor:GetSelection()
	-- We need to calculate the current_char_idx starting from the first line
	local current_char_idx = 1

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

	for i, line in ipairs(input_lines) do
		-- Only process lines that are visible
		if i >= visible_start and i <= visible_end then
			local prefix = (i == 1) and "> " or "  "
			-- Position lines relative to the bottom of the screen
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

			-- Handle newline selection
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
			-- If not visible, we still need to increment char index for correct selection highlights
			current_char_idx = current_char_idx + #line + 1 -- +1 for newline
		end
	end

	-- Draw blinking cursor
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

	term:PopAttribute()
	term:EndFrame()
	term:Flush()
end)

return tui