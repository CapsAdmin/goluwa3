local event = require("event")
local terminal = require("bindings.terminal")
local system = require("system")
local repl = {
	started = true,
	input_buffer = "",
	input_cursor = 1,
	selection_start = nil,
	history = {},
	history_index = 1,
	output_lines = {},
	scroll_offset = 0,
	input_scroll_offset = 0,
	needs_redraw = true,
	clipboard = "",
	debug = true,
	last_event = nil,
	raw_input = nil,
	saved_input = "", -- Saves current input when navigating history
}

function repl.CopyText()
	local start, stop = repl.GetSelection()

	if start then
		repl.clipboard = repl.input_buffer:sub(start, stop - 1)
		return true
	end

	return false
end

function repl.CutText()
	local start, stop = repl.GetSelection()

	if start then
		repl.clipboard = repl.input_buffer:sub(start, stop - 1)
		repl.DeleteSelection()
		return true
	end

	-- No selection - cut current line
	local line_start = repl.input_cursor
	local line_end = repl.input_cursor

	-- Find start of current line
	while line_start > 1 and repl.input_buffer:sub(line_start - 1, line_start - 1) ~= "\n" do
		line_start = line_start - 1
	end

	-- Find end of current line (including the newline if present)
	while
		line_end <= #repl.input_buffer and
		repl.input_buffer:sub(line_end, line_end) ~= "\n"
	do
		line_end = line_end + 1
	end

	-- Include the newline in the cut if present
	if
		line_end <= #repl.input_buffer and
		repl.input_buffer:sub(line_end, line_end) == "\n"
	then
		line_end = line_end + 1
	end

	-- Cut the line
	repl.clipboard = repl.input_buffer:sub(line_start, line_end - 1)
	repl.input_buffer = repl.input_buffer:sub(1, line_start - 1) .. repl.input_buffer:sub(line_end)
	repl.input_cursor = line_start
	repl.selection_start = nil
	return true
end

function repl.PasteText()
	if repl.clipboard ~= "" then
		repl.DeleteSelection()
		repl.input_buffer = repl.input_buffer:sub(1, repl.input_cursor - 1) .. repl.clipboard .. repl.input_buffer:sub(repl.input_cursor)
		repl.input_cursor = repl.input_cursor + #repl.clipboard
		return true
	end

	return false
end

function repl.DuplicateLine()
	local line_start = repl.input_cursor
	local line_end = repl.input_cursor

	-- Find start of current line
	while line_start > 1 and repl.input_buffer:sub(line_start - 1, line_start - 1) ~= "\n" do
		line_start = line_start - 1
	end

	-- Find end of current line (not including the newline)
	while
		line_end <= #repl.input_buffer and
		repl.input_buffer:sub(line_end, line_end) ~= "\n"
	do
		line_end = line_end + 1
	end

	-- Get the line content
	local line_content = repl.input_buffer:sub(line_start, line_end - 1)
	-- Insert duplicated line after current line
	repl.input_buffer = repl.input_buffer:sub(1, line_end - 1) .. "\n" .. line_content .. repl.input_buffer:sub(line_end)
	-- Move cursor to the start of the duplicated line
	repl.input_cursor = line_end + 1
	repl.selection_start = nil
end

local function get_char_class(char)
	if not char then return "none" end

	if char:match("[%w_]") then return "word" end

	if char:match("%s") then return "space" end

	return "other"
end

function repl.MoveWord(buffer, pos, dir)
	local new_pos = pos

	if dir == -1 then
		if new_pos <= 1 then return 1 end

		-- Skip initial spaces if we are moving left
		while new_pos > 1 and get_char_class(buffer:sub(new_pos - 1, new_pos - 1)) == "space" do
			new_pos = new_pos - 1
		end

		if new_pos <= 1 then return 1 end

		new_pos = new_pos - 1
		local class = get_char_class(buffer:sub(new_pos, new_pos))

		while new_pos > 1 and get_char_class(buffer:sub(new_pos - 1, new_pos - 1)) == class do
			new_pos = new_pos - 1
		end
	else
		-- Skip initial spaces if we are moving right
		while new_pos <= #buffer and get_char_class(buffer:sub(new_pos, new_pos)) == "space" do
			new_pos = new_pos + 1
		end

		if new_pos > #buffer then return #buffer + 1 end

		local class = get_char_class(buffer:sub(new_pos, new_pos))

		while new_pos <= #buffer and get_char_class(buffer:sub(new_pos, new_pos)) == class do
			new_pos = new_pos + 1
		end
	end

	return new_pos
end

function repl.GetSelection()
	if not repl.selection_start then return nil end

	local start = math.min(repl.selection_start, repl.input_cursor)
	local stop = math.max(repl.selection_start, repl.input_cursor)
	return start, stop
end

function repl.DeleteSelection()
	local start, stop = repl.GetSelection()

	if start then
		repl.input_buffer = repl.input_buffer:sub(1, start - 1) .. repl.input_buffer:sub(stop)
		repl.input_cursor = start
		repl.selection_start = nil
		return true
	end

	return false
end

local function get_cursor_pos(buffer, cursor)
	local line = 1
	local col = 1

	for i = 1, cursor - 1 do
		if buffer:sub(i, i) == "\n" then
			line = line + 1
			col = 1
		else
			col = col + 1
		end
	end

	return line, col
end

local function set_cursor_to_line_col(buffer, target_line, target_col)
	local line = 1
	local col = 1
	local pos = 1

	if target_line < 1 then return nil end

	for i = 1, #buffer do
		if line == target_line then if col == target_col then return pos end end

		if buffer:sub(i, i) == "\n" then
			if line == target_line then
				-- End of target line reached, clamp to line end
				return pos
			end

			line = line + 1
			col = 1
		else
			col = col + 1
		end

		pos = pos + 1
	end

	-- If we're on the target line at the end of buffer
	if line == target_line then return math.min(pos, #buffer + 1) end

	return nil
end

function repl.IsFocused()
	return true
end

function repl.StyledWrite(str)
	if not str:match("\n$") then str = str .. "\n" end

	for line in str:gmatch("(.-)\n") do
		table.insert(repl.output_lines, line)
	end

	repl.needs_redraw = true
end

function repl.InputLua(str)
	local func, err = loadstring(str)

	if func then
		local ok, res = pcall(func)

		if not ok then
			logn("Error: " .. tostring(res))
		elseif res ~= nil then
			logn(res)
		end
	else
		logn("Syntax Error: " .. tostring(err))
	end
end

function repl.HandleEvent(ev)
	if repl.debug then
		repl.last_event = ev
		repl.raw_input = ev.raw_input
	end

	repl.needs_redraw = true
	local old_cursor = repl.input_cursor

	if ev.key == "enter" then
		if ev.modifiers.shift then
			repl.DeleteSelection()
			repl.input_buffer = repl.input_buffer:sub(1, repl.input_cursor - 1) .. "\n" .. repl.input_buffer:sub(repl.input_cursor)
			repl.input_cursor = repl.input_cursor + 1
			-- Auto-scroll to show cursor if needed
			local cursor_line = get_cursor_pos(repl.input_buffer, repl.input_cursor)
			local input_lines_count = select(2, repl.input_buffer:gsub("\n", "")) + 1

			if input_lines_count > 5 then
				repl.input_scroll_offset = math.max(0, cursor_line - 5)
			end
		else
			if repl.input_buffer == "exit" then
				system.ShutDown(0)
				return
			end

			if repl.input_buffer == "clear" then
				repl.output_lines = {}
				repl.scroll_offset = 0
				repl.input_buffer = ""
				repl.input_cursor = 1
				repl.input_scroll_offset = 0
				repl.selection_start = nil
				repl.saved_input = ""
				return
			end

			logn("> " .. repl.input_buffer)

			if repl.input_buffer ~= "" then
				-- Don't add duplicate of the last history entry
				local is_duplicate = #repl.history > 0 and repl.history[#repl.history] == repl.input_buffer

				if not is_duplicate then
					table.insert(repl.history, repl.input_buffer)
				end

				repl.history_index = #repl.history + 1
				repl.InputLua(repl.input_buffer)
			end

			repl.input_buffer = ""
			repl.input_cursor = 1
			repl.scroll_offset = 0
			repl.input_scroll_offset = 0
			repl.selection_start = nil
			repl.saved_input = ""
		end
	elseif ev.key == "backspace" then
		if not repl.DeleteSelection() then
			if ev.modifiers.ctrl then
				local new_pos = repl.MoveWord(repl.input_buffer, repl.input_cursor, -1)
				repl.input_buffer = repl.input_buffer:sub(1, new_pos - 1) .. repl.input_buffer:sub(repl.input_cursor)
				repl.input_cursor = new_pos
			elseif repl.input_cursor > 1 then
				repl.input_buffer = repl.input_buffer:sub(1, repl.input_cursor - 2) .. repl.input_buffer:sub(repl.input_cursor)
				repl.input_cursor = repl.input_cursor - 1
			end
		end
	elseif ev.key == "delete" then
		if not repl.DeleteSelection() then
			if ev.modifiers.ctrl then
				local new_pos = repl.MoveWord(repl.input_buffer, repl.input_cursor, 1)
				repl.input_buffer = repl.input_buffer:sub(1, repl.input_cursor - 1) .. repl.input_buffer:sub(new_pos)
			elseif repl.input_cursor <= #repl.input_buffer then
				repl.input_buffer = repl.input_buffer:sub(1, repl.input_cursor - 1) .. repl.input_buffer:sub(repl.input_cursor + 1)
			end
		end
	elseif ev.key == "left" or ev.key == "right" or ev.key == "home" or ev.key == "end" then
		if ev.key == "left" then
			if ev.modifiers.ctrl then
				repl.input_cursor = repl.MoveWord(repl.input_buffer, repl.input_cursor, -1)
			else
				repl.input_cursor = math.max(1, repl.input_cursor - 1)
			end
		elseif ev.key == "right" then
			if ev.modifiers.ctrl then
				repl.input_cursor = repl.MoveWord(repl.input_buffer, repl.input_cursor, 1)
			else
				repl.input_cursor = math.min(#repl.input_buffer + 1, repl.input_cursor + 1)
			end
		elseif ev.key == "home" then
			-- Move to start of current line
			local pos = repl.input_cursor

			while pos > 1 and repl.input_buffer:sub(pos - 1, pos - 1) ~= "\n" do
				pos = pos - 1
			end

			repl.input_cursor = pos
		elseif ev.key == "end" then
			-- Move to end of current line
			local pos = repl.input_cursor

			while pos <= #repl.input_buffer and repl.input_buffer:sub(pos, pos) ~= "\n" do
				pos = pos + 1
			end

			repl.input_cursor = pos
		end

		if ev.modifiers.shift then
			if not repl.selection_start then repl.selection_start = old_cursor end
		else
			repl.selection_start = nil
		end
	elseif ev.key == "up" then
		local input_lines_count = select(2, repl.input_buffer:gsub("\n", "")) + 1
		local current_line, current_col = get_cursor_pos(repl.input_buffer, repl.input_cursor)

		if ev.modifiers.ctrl then
			-- Scroll input view up
			repl.input_scroll_offset = math.max(0, repl.input_scroll_offset - 1)
		elseif current_line > 1 then
			-- Move cursor up one line, preserving column
			local new_pos = set_cursor_to_line_col(repl.input_buffer, current_line - 1, current_col)

			if new_pos then
				repl.input_cursor = new_pos

				-- Auto-scroll to show cursor
				if repl.input_scroll_offset > 0 and current_line - 1 <= repl.input_scroll_offset then
					repl.input_scroll_offset = math.max(0, current_line - 2)
				end
			end
		elseif current_line == 1 and repl.history_index > 1 then
			-- At first line, trying to go up - navigate history
			-- Save current input if we're leaving fresh input mode
			if repl.history_index > #repl.history then
				repl.saved_input = repl.input_buffer
			end

			repl.history_index = repl.history_index - 1
			repl.input_buffer = repl.history[repl.history_index]
			repl.input_cursor = #repl.input_buffer + 1
			repl.input_scroll_offset = 0
			repl.selection_start = nil
		end
	elseif ev.key == "down" then
		local input_lines_count = select(2, repl.input_buffer:gsub("\n", "")) + 1
		local current_line, current_col = get_cursor_pos(repl.input_buffer, repl.input_cursor)

		if ev.modifiers.ctrl then
			-- Scroll input view down
			if input_lines_count > 5 then
				repl.input_scroll_offset = math.min(input_lines_count - 5, repl.input_scroll_offset + 1)
			end
		elseif current_line < input_lines_count then
			-- Move cursor down one line, preserving column
			local new_pos = set_cursor_to_line_col(repl.input_buffer, current_line + 1, current_col)

			if new_pos then
				repl.input_cursor = new_pos

				-- Auto-scroll to show cursor
				if input_lines_count > 5 and current_line + 1 > repl.input_scroll_offset + 5 then
					repl.input_scroll_offset = math.min(input_lines_count - 5, repl.input_scroll_offset + 1)
				end
			end
		elseif current_line == input_lines_count and repl.history_index < #repl.history then
			-- At last line, trying to go down - navigate history
			repl.history_index = repl.history_index + 1
			repl.input_buffer = repl.history[repl.history_index]
			repl.input_cursor = #repl.input_buffer + 1
			repl.input_scroll_offset = 0
			repl.selection_start = nil
		elseif current_line == input_lines_count and repl.history_index == #repl.history then
			-- Restore saved input when going back to fresh input mode
			repl.history_index = #repl.history + 1
			repl.input_buffer = repl.saved_input
			repl.input_cursor = #repl.input_buffer + 1
			repl.input_scroll_offset = 0
			repl.selection_start = nil
			repl.saved_input = ""
		end
	elseif ev.key == "pageup" then
		repl.scroll_offset = repl.scroll_offset + 10
	elseif ev.key == "pagedown" then
		repl.scroll_offset = math.max(0, repl.scroll_offset - 10)
	elseif ev.key == "a" and ev.modifiers.ctrl then
		-- Select all
		if #repl.input_buffer > 0 then
			repl.selection_start = 1
			repl.input_cursor = #repl.input_buffer + 1
		end
	elseif ev.key == "c" and ev.modifiers.ctrl then
		repl.CopyText()
	elseif ev.key == "d" and ev.modifiers.ctrl then
		repl.DuplicateLine()
	elseif ev.key == "q" and ev.modifiers.ctrl then
		system.ShutDown()
	elseif ev.key == "x" and ev.modifiers.ctrl then
		repl.CutText()
	elseif ev.key == "v" and ev.modifiers.ctrl then
		repl.PasteText()
	elseif ev.key == "l" and ev.modifiers.ctrl then
		repl.output_lines = {}
		repl.scroll_offset = 0
	elseif #ev.key == 1 then
		repl.DeleteSelection()
		repl.input_buffer = repl.input_buffer:sub(1, repl.input_cursor - 1) .. ev.key .. repl.input_buffer:sub(repl.input_cursor)
		repl.input_cursor = repl.input_cursor + 1
	end
end

local function draw(term)
	if not repl.needs_redraw then return end

	repl.needs_redraw = false
	term:BeginFrame()
	term:Clear()
	local w, h = term:GetSize()

	-- Draw debug info in top left corner
	if repl.debug and repl.last_event then
		local debug_info = string.format(
			"key=%s ctrl=%s shift=%s alt=%s",
			repl.last_event.key or "nil",
			tostring(repl.last_event.modifiers and repl.last_event.modifiers.ctrl or false),
			tostring(repl.last_event.modifiers and repl.last_event.modifiers.shift or false),
			tostring(repl.last_event.modifiers and repl.last_event.modifiers.alt or false)
		)
		term:PushForegroundColor(255, 255, 0)
		term:WriteStringToScreen(1, 1, debug_info)

		-- Show raw input bytes if available
		if repl.raw_input then
			local raw_hex = ""

			for i = 1, #repl.raw_input do
				raw_hex = raw_hex .. string.format("%02X ", repl.raw_input:byte(i))
			end

			local raw_info = "raw: " .. raw_hex

			if #raw_info > w then raw_info = raw_info:sub(1, w) end

			term:WriteStringToScreen(1, 2, raw_info)
		end

		term:PopAttribute()
	end

	-- Split input into lines
	local input_lines = {}

	for line in (repl.input_buffer .. "\n"):gmatch("(.-)\n") do
		table.insert(input_lines, line)
	end

	-- Calculate visible input lines (max 5)
	local visible_input_lines = math.min(5, #input_lines)
	-- Draw output (start from line 3 if debug is enabled with raw, line 1 otherwise)
	local output_start_line = repl.debug and 3 or 1
	local max_output_h = h - 1 - visible_input_lines - (repl.debug and 2 or 0)
	local total_lines = #repl.output_lines
	local start_idx = math.max(1, total_lines - max_output_h + 1 - repl.scroll_offset)

	for i = 0, max_output_h - 1 do
		local line = repl.output_lines[start_idx + i]

		if line then
			-- Truncate line if too long
			if #line > w then line = line:sub(1, w) end

			term:WriteStringToScreen(1, output_start_line + i, line)
		end
	end

	-- Draw separator
	local sep = string.rep("-", w)

	if repl.scroll_offset > 0 then
		local scroll_text = " SCROLL: " .. repl.scroll_offset .. " "
		sep = scroll_text .. string.rep("-", math.max(0, w - #scroll_text))
	end

	term:WriteStringToScreen(1, h - visible_input_lines, sep)
	-- Draw input
	local sel_start, sel_stop = repl.GetSelection()
	local current_char_idx = 1
	-- Calculate which lines to show with scrolling
	local start_line = repl.input_scroll_offset + 1
	local end_line = math.min(#input_lines, start_line + visible_input_lines - 1)

	-- Skip characters before the visible range
	for i = 1, start_line - 1 do
		current_char_idx = current_char_idx + #input_lines[i] + 1 -- +1 for newline
	end

	for i = start_line, end_line do
		local line = input_lines[i]
		local prefix = i == 1 and "> " or "  "
		local y = h - visible_input_lines + (i - start_line) + 1
		term:SetCaretPosition(1, y)
		term:Write(prefix)

		for j = 1, #line do
			local char = line:sub(j, j)
			local is_selected = sel_start and current_char_idx >= sel_start and current_char_idx < sel_stop

			if is_selected then
				term:PushBackgroundColor(100, 100, 100)
				term:Write(char)
				term:PopAttribute()
			else
				term:Write(char)
			end

			current_char_idx = current_char_idx + 1
		end

		-- Handle the newline character at the end of the line (except the last line)
		if i < #input_lines then
			local is_selected = sel_start and current_char_idx >= sel_start and current_char_idx < sel_stop

			if is_selected then
				term:PushBackgroundColor(100, 100, 100)
				term:Write(" ")
				term:PopAttribute()
			end

			current_char_idx = current_char_idx + 1
		end
	end

	local cursor_line, cursor_col = get_cursor_pos(repl.input_buffer, repl.input_cursor)

	-- Only show cursor if it's in the visible range
	if cursor_line >= start_line and cursor_line <= end_line then
		term:SetCaretPosition(
			math.min(w, 3 + cursor_col - 1),
			h - visible_input_lines + (cursor_line - start_line) + 1
		)
	end

	term:EndFrame()
end

function repl.Initialize()
	local term = terminal.WrapFile(io.stdin, io.stdout)
	term:UseAlternateScreen(true)
	term:Clear()
	term:EnableCaret(true)

	event.AddListener("Update", "repl", function()
		while true do
			local ev = term:ReadEvent()

			if not ev then break end

			repl.HandleEvent(ev)
		end

		draw(term)
	end)

	event.AddListener("ShutDown", "repl", function()
		term:UseAlternateScreen(false)
		term:EnableCaret(true)
	end)

	repl.term = term
end

return repl
