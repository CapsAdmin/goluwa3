--[[HOTRELOAD
test("repl")
]]
local event = require("event")
local terminal = require("bindings.terminal")
local system = require("system")
local output = require("output")
local commands = require("commands")
local codec = require("codec")
local clipboard = require("bindings.clipboard")
local utf8 = require("utf8")
local sequence_editor = require("sequence_editor")
local repl = library()
commands.history = codec.ReadFile("luadata", "data/cmd_history.txt") or {}

for _, v in ipairs(commands.history) do
	commands.history_map[v] = true
end

repl.started = true
repl.editor = repl.editor or sequence_editor.New()
repl.editor.OnChanged = function(s, text)
	repl.needs_redraw = true
end

function repl.GetSelection()
	return repl.editor:GetSelection()
end

function repl.DeleteSelection()
	return repl.editor:DeleteSelection()
end

function repl.CopyText()
	if not repl.editor:GetSelection() then
		local start, stop = repl.editor:GetCursorLineCol()
		repl.editor:SetCursorLineCol(start, 1)
		local line_start = repl.editor:GetCursor()
		local buffer = repl.editor:GetBuffer()
		local len = buffer:GetLength()

		while
			repl.editor:GetCursor() <= len and
			buffer:Sub(repl.editor:GetCursor(), repl.editor:GetCursor()) ~= "\n"
		do
			repl.editor:SetCursor(repl.editor:GetCursor() + 1)
		end

		if
			repl.editor:GetCursor() <= len and
			buffer:Sub(repl.editor:GetCursor(), repl.editor:GetCursor()) == "\n"
		then
			repl.editor:SetCursor(repl.editor:GetCursor() + 1)
		end

		local line_end = repl.editor:GetCursor()
		local str = buffer:Sub(line_start, line_end - 1)
		repl.editor:SetClipboard(str)
		repl.editor:SetCursor(line_start) -- restore cursor roughly
		return str
	end

	return repl.editor:Copy()
end

function repl.CutText()
	if not repl.editor:GetSelection() then
		local str = repl.CopyText()

		if str then
			repl.editor:SaveUndoState()
			local start = repl.editor:GetCursor()
			local stop = start + repl.editor:GetBuffer():GetLength(str)
			repl.editor:GetBuffer():RemoveRange(start, stop)
			repl.editor:SetText(repl.editor:GetBuffer():GetText())
			repl.editor:SetCursor(start)
		end

		return str
	end

	return repl.editor:Cut()
end

function repl.PasteText()
	local str = clipboard.Get()

	if str then
		repl.editor:Paste(str)
		return true
	end

	return false
end

function repl.DuplicateLine()
	return repl.editor:DuplicateLine()
end

setmetatable(
	repl,
	{
		__index = function(t, k)
			if k == "input_buffer" then return t.editor:GetBuffer():GetText() end

			if k == "input_cursor" then return t.editor:GetCursor() end

			if k == "selection_start" then return t.editor:GetSelectionStart() end
		end,
		__newindex = function(t, k, v)
			if k == "input_buffer" then
				t.editor:SetText(v)
			elseif k == "input_cursor" then
				t.editor:SetCursor(v)
			elseif k == "selection_start" then
				t.editor:SetSelectionStart(v)
			else
				rawset(t, k, v)
			end
		end,
	}
)
repl.history_index = repl.history_index or #commands.history + 1
repl.input_scroll_offset = repl.input_scroll_offset or 0
repl.needs_redraw = repl.needs_redraw or true
repl.debug = false
repl.last_event = repl.last_event or nil
repl.raw_input = repl.raw_input or nil
repl.saved_input = repl.saved_input or "" -- Saves current input when navigating history
repl.is_executing = repl.is_executing or false -- Tracks if we're executing a command
repl.last_drawn_lines = 0 -- Track how many lines we drew last frame
function repl.IsFocused()
	return true
end

do
	local Code = require("nattlua.code")
	local Lexer = require("nattlua.lexer.lexer")
	local colors = {
		keyword = "#569cd6",
		operator = "#d4d4d4",
		symbol = "#d4d4d4",
		number = "#b5cea8",
		string = "#ce9178",
		comment = "#6a9955",
		any = "#9cdcfe",
		["function"] = "#dcdcaa",
		table = "#4ec9b0",
		["type"] = "#4ec9b0",
		letter = "#d4d4d4",
	}

	for key, hex in pairs(colors) do
		local r, g, b = hex:match("#?(..)(..)(..)")
		r = tonumber("0x" .. r)
		g = tonumber("0x" .. g)
		b = tonumber("0x" .. b)
		colors[key] = {r, g, b}
	end

	function repl.ColorizeAndWrite(term, str)
		local ok, tokens = pcall(function()
			return Lexer.New(Code.New(str, "repl")):GetTokens()
		end)

		if not ok then
			-- Lexer failed, just write plain text
			term:Write(str)
			return
		end

		local last_color = nil

		local function set_color(what)
			if not colors[what] then what = "letter" end

			if what ~= last_color then
				local c = colors[what]
				term:ForegroundColor(c[1], c[2], c[3])
				last_color = what
			end
		end

		for _, token in ipairs(tokens) do
			-- Write whitespace if present
			if token:HasWhitespace() then
				for _, v in ipairs(token:GetWhitespace()) do
					if v.Type == "line_comment" or v.Type == "multiline_comment" then
						set_color("comment")
					end

					term:Write(v:GetValueString())
				end
			end

			-- Always write the token itself
			if token:IsKeyword() then
				set_color("keyword")
			elseif token:IsKeywordValue() then
				set_color("keyword")
			elseif token:IsSymbol() then
				set_color("symbol")
			elseif token:IsOperator() then
				set_color("operator")
			elseif token:IsNumber() then
				set_color("number")
			elseif token:IsString() then
				set_color("string")
			elseif token:IsAny() then
				set_color("any")
			elseif token:IsFunction() then
				set_color("function")
			elseif token:IsTable() then
				set_color("table")
			elseif token:IsOtherType() then
				set_color("type")
			else
				set_color(token.Type)
			end

			term:Write(token:GetValueString())

			if token.Type == "end_of_file" then break end
		end
	end
end

function repl.InputLua(str)
	repl.is_executing = true

	if str:find("cd ", nil, true) and str:find(" && luajit", nil, true) then
		local script = str:match(".+luajit.+'(.+%.lua)")
		str = "HOTRELOAD = true; dofile('" .. script .. "'); HOTRELOAD = nil"
	end

	commands.RunString(str)
	-- Flush stdout to capture any pending print() output
	output.Flush()
	repl.is_executing = false
end

-- Wrap a line of text to fit within a given width, accounting for prefix
local function wrap_line(line, width, prefix_width)
	if line:utf8_length() == 0 then return {""} end

	local wrapped = {}
	-- Reduce by 1 to avoid terminal auto-wrap issues when writing to the last column
	local available_width = width - prefix_width - 1

	if available_width <= 0 then
		available_width = width - 2 -- Minimum fallback
	end

	local pos = 1

	while pos <= line:utf8_length() do
		local chunk_end = math.min(pos + available_width - 1, line:utf8_length())
		table.insert(wrapped, line:utf8_sub(pos, chunk_end))
		pos = chunk_end + 1
	end

	return wrapped
end

-- Calculate which wrapped line contains a cursor at a given buffer position
local function get_wrapped_line_for_cursor(buffer, cursor_pos, width)
	local input_lines = {}

	for _, line in ipairs(buffer:split("\n")) do
		table.insert(input_lines, line)
	end

	local cursor_line, cursor_col = repl.editor:GetCursorLineCol(cursor_pos)
	local wrapped_line_idx = 0

	for i = 1, #input_lines do
		local prefix_width = (i == 1) and 2 or 2
		local wrapped = wrap_line(input_lines[i], width, prefix_width)

		if i < cursor_line then
			wrapped_line_idx = wrapped_line_idx + #wrapped
		elseif i == cursor_line then
			local available_width = width - prefix_width
			local wrap_index = math.ceil(cursor_col / available_width)

			if wrap_index < 1 then wrap_index = 1 end

			-- Clamp to actual number of wraps (cursor at end shouldn't create phantom line)
			if wrap_index > #wrapped then wrap_index = #wrapped end

			wrapped_line_idx = wrapped_line_idx + wrap_index

			break
		end
	end

	return wrapped_line_idx
end

function repl.HandleEvent(ev)
	if repl.debug then
		repl.last_event = ev
		repl.raw_input = ev.raw_input
	end

	repl.needs_redraw = true

	if ev.key then
		repl.editor:SetShiftDown(ev.modifiers and ev.modifiers.shift or false)
		repl.editor:SetControlDown(ev.modifiers and ev.modifiers.ctrl or false)

		if ev.key == "enter" then
			if ev.modifiers and ev.modifiers.shift then
				repl.editor:OnKeyInput("enter")
				-- Auto-scroll to show cursor if needed (using wrapped lines)
				local w = repl.term and repl.term:GetSize() or 80 -- Default width for tests
				local buffer = repl.editor:GetText()
				local cursor_wrapped_line = get_wrapped_line_for_cursor(buffer, repl.editor:GetCursor(), w)
				-- Calculate total wrapped lines
				local input_lines = {}

				for line in (buffer .. "\n"):gmatch("(.-)\n") do
					table.insert(input_lines, line)
				end

				local total_wrapped_lines = 0

				for i, line in ipairs(input_lines) do
					local prefix_width = (i == 1) and 2 or 2
					local wrapped = wrap_line(line, w, prefix_width)
					total_wrapped_lines = total_wrapped_lines + #wrapped
				end

				if total_wrapped_lines > 5 then
					-- Ensure cursor is visible
					if cursor_wrapped_line > repl.input_scroll_offset + 5 then
						repl.input_scroll_offset = cursor_wrapped_line - 5
					elseif cursor_wrapped_line <= repl.input_scroll_offset then
						repl.input_scroll_offset = math.max(0, cursor_wrapped_line - 1)
					end
				end
			else
				local buffer = repl.editor:GetText()

				if buffer == "exit" then
					system.ShutDown(0)
					return
				end

				if buffer == "clear" then
					repl.editor:SetText("")
					repl.editor:SetCursor(1)
					repl.input_scroll_offset = 0
					repl.editor:SetSelectionStart(nil)
					repl.saved_input = ""
					repl.term:Clear()
					return
				end

				logn("> " .. buffer)

				if buffer ~= "" then
					commands.AddHistory(buffer)
					repl.history_index = #commands.history + 1
					repl.InputLua(buffer)
					codec.WriteFile("luadata", "data/cmd_history.txt", commands.history)
				end

				repl.editor:SetText("")
				repl.editor:SetCursor(1)
				repl.input_scroll_offset = 0
				repl.editor:SetSelectionStart(nil)
				repl.saved_input = ""
			end
		elseif ev.key == "up" then
			local buffer = repl.editor:GetText()
			local input_lines_count = select(2, buffer:gsub("\n", "")) + 1
			local current_line, current_col = repl.editor:GetCursorLineCol()

			if ev.modifiers and ev.modifiers.ctrl then
				-- Scroll input view up (by wrapped lines)
				repl.input_scroll_offset = math.max(0, repl.input_scroll_offset - 1)
			elseif current_line > 1 then
				-- Move cursor up one line, preserving column
				repl.editor:OnKeyInput("up")

				-- Auto-scroll to show cursor
				if repl.input_scroll_offset > 0 and current_line - 1 <= repl.input_scroll_offset then
					repl.input_scroll_offset = math.max(0, current_line - 2)
				end
			elseif current_line == 1 and repl.history_index > 1 then
				-- At first line, trying to go up - navigate history
				-- Save current input if we're leaving fresh input mode
				if repl.history_index > #commands.history then
					repl.saved_input = buffer
				end

				repl.history_index = repl.history_index - 1
				repl.editor:SetText(commands.history[repl.history_index])
				repl.editor:SetCursor(repl.editor:GetBuffer():GetLength() + 1)
				repl.input_scroll_offset = 0
				repl.editor:SetSelectionStart(nil)
			end
		elseif ev.key == "down" then
			local buffer = repl.editor:GetText()
			local input_lines_count = select(2, buffer:gsub("\n", "")) + 1
			local current_line, current_col = repl.editor:GetCursorLineCol()

			if ev.modifiers and ev.modifiers.ctrl then
				-- Scroll input view down (by wrapped lines)
				local w = repl.term and repl.term:GetSize() or 80 -- Default width for tests
				local input_lines = {}

				for line in (buffer .. "\n"):gmatch("(.-)\n") do
					table.insert(input_lines, line)
				end

				local total_wrapped_lines = 0

				for i, line in ipairs(input_lines) do
					local prefix_width = (i == 1) and 2 or 2
					local wrapped = wrap_line(line, w, prefix_width)
					total_wrapped_lines = total_wrapped_lines + #wrapped
				end

				if total_wrapped_lines > 5 then
					repl.input_scroll_offset = math.min(total_wrapped_lines - 5, repl.input_scroll_offset + 1)
				end
			elseif current_line < input_lines_count then
				-- Move cursor down one line, preserving column
				repl.editor:OnKeyInput("down")

				-- Auto-scroll to show cursor
				if input_lines_count > 5 and current_line + 1 > repl.input_scroll_offset + 5 then
					repl.input_scroll_offset = math.min(input_lines_count - 5, repl.input_scroll_offset + 1)
				end
			elseif current_line == input_lines_count and repl.history_index < #commands.history then
				-- At last line, trying to go down - navigate history
				repl.history_index = repl.history_index + 1
				repl.editor:SetText(commands.history[repl.history_index])
				repl.editor:SetCursor(repl.editor:GetBuffer():GetLength() + 1)
				repl.input_scroll_offset = 0
				repl.editor:SetSelectionStart(nil)
			elseif current_line == input_lines_count and repl.history_index == #commands.history then
				-- Restore saved input when going back to fresh input mode
				repl.history_index = #commands.history + 1
				repl.editor:SetText(repl.saved_input)
				repl.editor:SetCursor(repl.editor:GetBuffer():GetLength() + 1)
				repl.input_scroll_offset = 0
				repl.editor:SetSelectionStart(nil)
				repl.saved_input = ""
			end
		elseif ev.key == "q" and ev.modifiers and ev.modifiers.ctrl then
			system.ShutDown()
		elseif ev.modifiers and ev.modifiers.ctrl then
			if ev.key == "c" then
				repl.CopyText()
			elseif ev.key == "x" then
				repl.CutText()
			elseif ev.key == "v" then
				repl.PasteText()
			else
				repl.editor:OnKeyInput(ev.key)
			end
		elseif #ev.key == 1 and not (ev.modifiers and ev.modifiers.ctrl) then
			repl.editor:OnCharInput(ev.key)
			-- Auto-scroll to show cursor if needed
			local w = repl.term and repl.term:GetSize() or 80 -- Default width for tests
			local buffer = repl.editor:GetText()
			local cursor_wrapped_line = get_wrapped_line_for_cursor(buffer, repl.editor:GetCursor(), w)
			-- Calculate total wrapped lines
			local input_lines = {}

			for line in (buffer .. "\n"):gmatch("(.-)\n") do
				table.insert(input_lines, line)
			end

			local total_wrapped_lines = 0

			for i, line in ipairs(input_lines) do
				local prefix_width = (i == 1) and 2 or 2
				local wrapped = wrap_line(line, w, prefix_width)
				total_wrapped_lines = total_wrapped_lines + #wrapped
			end

			if total_wrapped_lines > 5 then
				-- Ensure cursor is visible
				if cursor_wrapped_line > repl.input_scroll_offset + 5 then
					repl.input_scroll_offset = cursor_wrapped_line - 5
				elseif cursor_wrapped_line <= repl.input_scroll_offset then
					repl.input_scroll_offset = math.max(0, cursor_wrapped_line - 1)
				end
			end
		else
			repl.editor:OnKeyInput(ev.key)
		end
	end
end

-- Clear the display area we drew last time
local function clear_display(term)
	if repl.last_drawn_lines > 0 then
		-- Move to beginning of current line first
		term:Write("\r")

		-- Move up to the start of our display area
		if repl.last_drawn_lines > 1 then term:MoveUp(repl.last_drawn_lines - 1) end

		-- Clear each line
		for i = 1, repl.last_drawn_lines do
			term:ClearCurrentLine()

			if i < repl.last_drawn_lines then term:MoveDown(1) end
		end

		-- Move back to the start
		if repl.last_drawn_lines > 1 then term:MoveUp(repl.last_drawn_lines - 1) end

		term:Write("\r")
	end
end

local function draw(term)
	if not repl.needs_redraw then return end

	repl.needs_redraw = false
	local w, h = term:GetSize()
	-- Clear previous display
	clear_display(term)
	term:BeginFrame()
	local buffer = repl.editor:GetText()
	-- Split input into lines
	local input_lines = {}

	for line in (buffer .. "\n"):gmatch("(.-)\n") do
		table.insert(input_lines, line)
	end

	-- Wrap lines to terminal width
	local wrapped_lines = {}
	local line_map = {} -- Maps wrapped line index to {original_line, char_start (1-based), char_end (inclusive)}
	for i, line in ipairs(input_lines) do
		local prefix_width = (i == 1) and 2 or 2 -- "> " or "  "
		local wrapped = wrap_line(line, w, prefix_width)
		local char_start = 1

		for j, wrapped_line in ipairs(wrapped) do
			table.insert(
				wrapped_lines,
				{original_line_idx = i, wrapped_text = wrapped_line, is_first_wrap = (j == 1)}
			)
			local wrapped_length = wrapped_line:utf8_length()
			local char_end = char_start + wrapped_length - 1
			table.insert(line_map, {original_line = i, char_start = char_start, char_end = char_end})
			char_start = char_end + 1
		end
	end

	-- Calculate visible input lines (max 5 wrapped lines)
	local visible_input_lines = math.min(5, #wrapped_lines)
	local total_display_lines = visible_input_lines
	-- Draw input
	local sel_start, sel_stop = repl.editor:GetSelection()
	local current_char_idx = 1
	-- Calculate which lines to show with scrolling
	local start_line = repl.input_scroll_offset + 1
	local end_line = math.min(#wrapped_lines, start_line + visible_input_lines - 1)

	-- Skip characters before the visible range
	for i = 1, start_line - 1 do
		local map = line_map[i]

		if i > 1 and line_map[i - 1].original_line ~= map.original_line then
			current_char_idx = current_char_idx + 1 -- +1 for newline between original lines
		end

		current_char_idx = current_char_idx + wrapped_lines[i].wrapped_text:utf8_length()
	end

	local cursor_screen_line = 1
	local cursor_screen_col = 3

	for i = start_line, end_line do
		local wrapped_info = wrapped_lines[i]
		local line = wrapped_info.wrapped_text
		local map = line_map[i]
		local prefix = (map.original_line == 1 and wrapped_info.is_first_wrap) and "> " or "  "
		local display_line_num = i - start_line + 1
		term:Write(prefix)

		-- Use styled rendering if no selection, otherwise render char by char with selection
		if not sel_start then
			-- No selection - use syntax highlighting
			repl.ColorizeAndWrite(term, line)
			term:NoAttributes()
			current_char_idx = current_char_idx + line:utf8_length()
		else
			-- Has selection - render char by char with selection highlighting
			for j = 1, line:utf8_length() do
				local char = line:utf8_sub(j, j)
				local is_selected = current_char_idx >= sel_start and current_char_idx < sel_stop

				if is_selected then
					term:PushBackgroundColor(100, 100, 100)
					term:Write(char)
					term:PopAttribute()
				else
					term:Write(char)
				end

				current_char_idx = current_char_idx + 1
			end
		end

		-- Handle the newline character between original lines
		if i < #wrapped_lines then
			local next_map = line_map[i + 1]

			if next_map.original_line ~= map.original_line then
				-- This is the end of an original line, account for newline character
				if sel_start then
					local is_selected = current_char_idx >= sel_start and current_char_idx < sel_stop

					if is_selected then
						term:PushBackgroundColor(100, 100, 100)
						term:Write(" ")
						term:PopAttribute()
					end
				end

				current_char_idx = current_char_idx + 1
			end
		end

		term:ClearLine()

		if display_line_num < visible_input_lines then term:Write("\n") end
	end

	-- Calculate cursor position in wrapped lines
	local cursor_line, cursor_col = repl.editor:GetCursorLineCol()
	local cursor_wrapped_line = 1
	local cursor_wrapped_col = cursor_col

	-- Find which wrapped line the cursor is on
	for i, map in ipairs(line_map) do
		if map.original_line == cursor_line then
			-- Check if cursor_col falls within this wrapped segment
			if cursor_col >= map.char_start and cursor_col <= map.char_end then
				cursor_wrapped_line = i
				cursor_wrapped_col = cursor_col - map.char_start + 1

				break
			elseif cursor_col == map.char_end + 1 then
				-- Cursor is right after the last char of this segment
				-- Place it at the end of this wrapped line
				cursor_wrapped_line = i
				cursor_wrapped_col = map.char_end - map.char_start + 2

				break
			end
		end
	end

	-- Only position cursor if it's in the visible range
	if cursor_wrapped_line >= start_line and cursor_wrapped_line <= end_line then
		cursor_screen_line = cursor_wrapped_line - start_line + 1
		cursor_screen_col = 3 + cursor_wrapped_col - 1
	end

	term:EndFrame()
	-- Position cursor (move up if we're not on the last line)
	local lines_to_move_up = visible_input_lines - cursor_screen_line

	if lines_to_move_up > 0 then term:MoveUp(lines_to_move_up) end

	term:MoveToColumn(math.min(w, cursor_screen_col))

	-- Move back down for next frame's reference
	if lines_to_move_up > 0 then
		term:SaveCursor()
		term:MoveDown(lines_to_move_up)
		term:RestoreCursor()
	end

	repl.last_drawn_lines = total_display_lines
	term:Flush()
end

function repl.Initialize()
	require("logging").ReplMode()
	local stdout_handle = output.original_stdout_file or io.stdout
	local term = terminal.WrapFile(io.stdin, stdout_handle)
	-- Don't use alternate screen - let output flow naturally
	term:EnableCaret(true)
	repl.term = term

	event.AddListener("Update", "repl", function()
		-- Process any pending stdout data from the pipe
		output.Flush()

		while true do
			local ev = term:ReadEvent()

			if not ev then break end

			repl.HandleEvent(ev)
		end

		draw(term)
	end)

	event.AddListener("StdOutWrite", "repl", function(str)
		if repl.started then
			-- Clear current display before output is written
			if repl.term then
				clear_display(repl.term)
				repl.term:Flush()
				repl.last_drawn_lines = 0
			end

			-- Style the output with "< " prefix when executing
			if repl.is_executing and repl.term then
				-- Process each line and add the prefix
				local lines = {}

				for line in (str .. "\n"):gmatch("(.-)\n") do
					table.insert(lines, line)
				end

				-- Remove trailing empty line caused by the pattern when string ends with \n
				if #lines > 0 and lines[#lines] == "" then table.remove(lines) end

				for i, line in ipairs(lines) do
					-- Output styling: dim cyan "< " prefix
					-- Output styling: dim cyan "< " prefix
					repl.term:PushDim()
					repl.term:PushForegroundColor(100, 180, 180)
					repl.term:Write("< ")
					repl.term:PopAttribute()
					repl.term:PopAttribute()
					-- Write the actual output line with syntax highlighting
					repl.ColorizeAndWrite(repl.term, line)
					repl.term:NoAttributes()

					if i < #lines or str:match("\n$") then repl.term:Write("\n") end
				end

				repl.term:Flush()
				repl.needs_redraw = true
				return false -- We handled the output ourselves (log already written by output.lua)
			end

			-- Allow output to proceed, prompt will redraw on next update
			repl.needs_redraw = true
			return true
		end
	end)

	event.AddListener("ShutDown", "repl", function()
		-- Just move to a new line, don't clear the display
		-- This preserves the output history in the terminal
		if term then
			term:NoAttributes()
			term:Write("\n")
			term:Flush()
			term:Close()
		end

		output.Flush()
	end)

	-- Initial draw
	draw(term)
end

return repl
