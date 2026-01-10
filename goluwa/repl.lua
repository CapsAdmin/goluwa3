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
local repl = library()
commands.history = codec.ReadFile("luadata", "data/cmd_history.txt") or {}

for _, v in ipairs(commands.history) do
	commands.history_map[v] = true
end

repl.started = true
repl.input_buffer = repl.input_buffer or ""
repl.input_cursor = repl.input_cursor or 1
repl.selection_start = repl.selection_start or nil
repl.history_index = repl.history_index or #commands.history + 1
repl.input_scroll_offset = repl.input_scroll_offset or 0
repl.needs_redraw = repl.needs_redraw or true
repl.debug = false
repl.last_event = repl.last_event or nil
repl.raw_input = repl.raw_input or nil
repl.saved_input = repl.saved_input or "" -- Saves current input when navigating history
repl.is_executing = repl.is_executing or false -- Tracks if we're executing a command
repl.last_drawn_lines = 0 -- Track how many lines we drew last frame
function repl.CopyText()
	local start, stop = repl.GetSelection()

	if start then
		clipboard.Set(repl.input_buffer:utf8_sub(start, stop - 1))
		return true
	end

	return false
end

function repl.CutText()
	local start, stop = repl.GetSelection()

	if start then
		clipboard.Set(repl.input_buffer:utf8_sub(start, stop - 1))
		repl.DeleteSelection()
		return true
	end

	-- No selection - cut current line
	local line_start = repl.input_cursor
	local line_end = repl.input_cursor

	-- Find start of current line
	while
		line_start > 1 and
		repl.input_buffer:utf8_sub(line_start - 1, line_start - 1) ~= "\n"
	do
		line_start = line_start - 1
	end

	-- Find end of current line (including the newline if present)
	while
		line_end <= repl.input_buffer:utf8_length() and
		repl.input_buffer:utf8_sub(line_end, line_end) ~= "\n"
	do
		line_end = line_end + 1
	end

	-- Include the newline in the cut if present
	if
		line_end <= repl.input_buffer:utf8_length() and
		repl.input_buffer:utf8_sub(line_end, line_end) == "\n"
	then
		line_end = line_end + 1
	end

	-- Cut the line
	clipboard.Set(repl.input_buffer:utf8_sub(line_start, line_end - 1))
	repl.input_buffer = repl.input_buffer:utf8_sub(1, line_start - 1) .. repl.input_buffer:utf8_sub(line_end)
	repl.input_cursor = line_start
	repl.selection_start = nil
	return true
end

function repl.PasteText()
	local str = clipboard.Get()

	if str and str ~= "" then
		repl.DeleteSelection()
		repl.input_buffer = repl.input_buffer:utf8_sub(1, repl.input_cursor - 1) .. str .. repl.input_buffer:utf8_sub(repl.input_cursor)
		repl.input_cursor = repl.input_cursor + str:utf8_length()
		return true
	end

	return false
end

function repl.DuplicateLine()
	local line_start = repl.input_cursor
	local line_end = repl.input_cursor

	-- Find start of current line
	while
		line_start > 1 and
		repl.input_buffer:utf8_sub(line_start - 1, line_start - 1) ~= "\n"
	do
		line_start = line_start - 1
	end

	-- Find end of current line (not including the newline)
	while
		line_end <= repl.input_buffer:utf8_length() and
		repl.input_buffer:utf8_sub(line_end, line_end) ~= "\n"
	do
		line_end = line_end + 1
	end

	-- Get the line content
	local line_content = repl.input_buffer:utf8_sub(line_start, line_end - 1)
	-- Insert duplicated line after current line
	repl.input_buffer = repl.input_buffer:utf8_sub(1, line_end - 1) .. "\n" .. line_content .. repl.input_buffer:utf8_sub(line_end)
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
		while
			new_pos > 1 and
			get_char_class(buffer:utf8_sub(new_pos - 1, new_pos - 1)) == "space"
		do
			new_pos = new_pos - 1
		end

		if new_pos <= 1 then return 1 end

		new_pos = new_pos - 1
		local class = get_char_class(buffer:utf8_sub(new_pos, new_pos))

		while
			new_pos > 1 and
			get_char_class(buffer:utf8_sub(new_pos - 1, new_pos - 1)) == class
		do
			new_pos = new_pos - 1
		end
	else
		-- Skip initial spaces if we are moving right
		while
			new_pos <= buffer:utf8_length() and
			get_char_class(buffer:utf8_sub(new_pos, new_pos)) == "space"
		do
			new_pos = new_pos + 1
		end

		if new_pos > buffer:utf8_length() then return buffer:utf8_length() + 1 end

		local class = get_char_class(buffer:utf8_sub(new_pos, new_pos))

		while
			new_pos <= buffer:utf8_length() and
			get_char_class(buffer:utf8_sub(new_pos, new_pos)) == class
		do
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
		repl.input_buffer = repl.input_buffer:utf8_sub(1, start - 1) .. repl.input_buffer:utf8_sub(stop)
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
		if buffer:utf8_sub(i, i) == "\n" then
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

	for i = 1, buffer:utf8_length() do
		if line == target_line then if col == target_col then return pos end end

		if buffer:utf8_sub(i, i) == "\n" then
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
	if line == target_line then return math.min(pos, buffer:utf8_length() + 1) end

	return nil
end

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

	local cursor_line, cursor_col = get_cursor_pos(buffer, cursor_pos)
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
	local old_cursor = repl.input_cursor

	if ev.key then
		if ev.key == "enter" then
			if ev.modifiers and ev.modifiers.shift then
				repl.DeleteSelection()
				repl.input_buffer = repl.input_buffer:utf8_sub(1, repl.input_cursor - 1) .. "\n" .. repl.input_buffer:utf8_sub(repl.input_cursor)
				repl.input_cursor = repl.input_cursor + 1
				-- Auto-scroll to show cursor if needed (using wrapped lines)
				local w = repl.term and repl.term:GetSize() or 80 -- Default width for tests
				local cursor_wrapped_line = get_wrapped_line_for_cursor(repl.input_buffer, repl.input_cursor, w)
				-- Calculate total wrapped lines
				local input_lines = {}

				for line in (repl.input_buffer .. "\n"):gmatch("(.-)\n") do
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
				if repl.input_buffer == "exit" then
					system.ShutDown(0)
					return
				end

				if repl.input_buffer == "clear" then
					repl.input_buffer = ""
					repl.input_cursor = 1
					repl.input_scroll_offset = 0
					repl.selection_start = nil
					repl.saved_input = ""
					repl.term:Clear()
					return
				end

				logn("> " .. repl.input_buffer)

				if repl.input_buffer ~= "" then
					commands.AddHistory(repl.input_buffer)
					repl.history_index = #commands.history + 1
					repl.InputLua(repl.input_buffer)
					codec.WriteFile("luadata", "data/cmd_history.txt", commands.history)
				end

				repl.input_buffer = ""
				repl.input_cursor = 1
				repl.input_scroll_offset = 0
				repl.selection_start = nil
				repl.saved_input = ""
			end
		elseif ev.key == "backspace" then
			if not repl.DeleteSelection() then
				if ev.modifiers and ev.modifiers.ctrl then
					local new_pos = repl.MoveWord(repl.input_buffer, repl.input_cursor, -1)
					repl.input_buffer = repl.input_buffer:utf8_sub(1, new_pos - 1) .. repl.input_buffer:utf8_sub(repl.input_cursor)
					repl.input_cursor = new_pos
				elseif repl.input_cursor > 1 then
					repl.input_buffer = repl.input_buffer:utf8_sub(1, repl.input_cursor - 2) .. repl.input_buffer:utf8_sub(repl.input_cursor)
					repl.input_cursor = repl.input_cursor - 1
				end
			end
		elseif ev.key == "delete" then
			if not repl.DeleteSelection() then
				if ev.modifiers and ev.modifiers.ctrl then
					local new_pos = repl.MoveWord(repl.input_buffer, repl.input_cursor, 1)
					repl.input_buffer = repl.input_buffer:utf8_sub(1, repl.input_cursor - 1) .. repl.input_buffer:utf8_sub(new_pos)
				elseif repl.input_cursor <= repl.input_buffer:utf8_length() then
					repl.input_buffer = repl.input_buffer:utf8_sub(1, repl.input_cursor - 1) .. repl.input_buffer:utf8_sub(repl.input_cursor + 1)
				end
			end
		elseif ev.key == "left" or ev.key == "right" or ev.key == "home" or ev.key == "end" then
			if ev.key == "left" then
				if ev.modifiers and ev.modifiers.ctrl then
					repl.input_cursor = repl.MoveWord(repl.input_buffer, repl.input_cursor, -1)
				else
					repl.input_cursor = math.max(1, repl.input_cursor - 1)
				end
			elseif ev.key == "right" then
				if ev.modifiers and ev.modifiers.ctrl then
					repl.input_cursor = repl.MoveWord(repl.input_buffer, repl.input_cursor, 1)
				else
					repl.input_cursor = math.min(repl.input_buffer:utf8_length() + 1, repl.input_cursor + 1)
				end
			elseif ev.key == "home" then
				-- Move to start of current line
				local pos = repl.input_cursor

				while pos > 1 and repl.input_buffer:utf8_sub(pos - 1, pos - 1) ~= "\n" do
					pos = pos - 1
				end

				repl.input_cursor = pos
			elseif ev.key == "end" then
				-- Move to end of current line
				local pos = repl.input_cursor

				while
					pos <= repl.input_buffer:utf8_length() and
					repl.input_buffer:utf8_sub(pos, pos) ~= "\n"
				do
					pos = pos + 1
				end

				repl.input_cursor = pos
			end

			if ev.modifiers and ev.modifiers.shift then
				if not repl.selection_start then repl.selection_start = old_cursor end
			else
				repl.selection_start = nil
			end
		elseif ev.key == "up" then
			local input_lines_count = select(2, repl.input_buffer:gsub("\n", "")) + 1
			local current_line, current_col = get_cursor_pos(repl.input_buffer, repl.input_cursor)

			if ev.modifiers and ev.modifiers.ctrl then
				-- Scroll input view up (by wrapped lines)
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
				if repl.history_index > #commands.history then
					repl.saved_input = repl.input_buffer
				end

				repl.history_index = repl.history_index - 1
				repl.input_buffer = commands.history[repl.history_index]
				repl.input_cursor = repl.input_buffer:utf8_length() + 1
				repl.input_scroll_offset = 0
				repl.selection_start = nil
			end
		elseif ev.key == "down" then
			local input_lines_count = select(2, repl.input_buffer:gsub("\n", "")) + 1
			local current_line, current_col = get_cursor_pos(repl.input_buffer, repl.input_cursor)

			if ev.modifiers and ev.modifiers.ctrl then
				-- Scroll input view down (by wrapped lines)
				local w = repl.term and repl.term:GetSize() or 80 -- Default width for tests
				local input_lines = {}

				for line in (repl.input_buffer .. "\n"):gmatch("(.-)\n") do
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
				local new_pos = set_cursor_to_line_col(repl.input_buffer, current_line + 1, current_col)

				if new_pos then
					repl.input_cursor = new_pos

					-- Auto-scroll to show cursor
					if input_lines_count > 5 and current_line + 1 > repl.input_scroll_offset + 5 then
						repl.input_scroll_offset = math.min(input_lines_count - 5, repl.input_scroll_offset + 1)
					end
				end
			elseif current_line == input_lines_count and repl.history_index < #commands.history then
				-- At last line, trying to go down - navigate history
				repl.history_index = repl.history_index + 1
				repl.input_buffer = commands.history[repl.history_index]
				repl.input_cursor = repl.input_buffer:utf8_length() + 1
				repl.input_scroll_offset = 0
				repl.selection_start = nil
			elseif current_line == input_lines_count and repl.history_index == #commands.history then
				-- Restore saved input when going back to fresh input mode
				repl.history_index = #commands.history + 1
				repl.input_buffer = repl.saved_input
				repl.input_cursor = repl.input_buffer:utf8_length() + 1
				repl.input_scroll_offset = 0
				repl.selection_start = nil
				repl.saved_input = ""
			end
		elseif ev.key == "a" and ev.modifiers and ev.modifiers.ctrl then
			-- Select all
			if repl.input_buffer:utf8_length() > 0 then
				repl.selection_start = 1
				repl.input_cursor = repl.input_buffer:utf8_length() + 1
			end
		elseif ev.key == "c" and ev.modifiers and ev.modifiers.ctrl then
			repl.CopyText()
		elseif ev.key == "d" and ev.modifiers and ev.modifiers.ctrl then
			repl.DuplicateLine()
		elseif ev.key == "q" and ev.modifiers and ev.modifiers.ctrl then
			system.ShutDown()
		elseif ev.key == "x" and ev.modifiers and ev.modifiers.ctrl then
			repl.CutText()
		elseif ev.key == "v" and ev.modifiers and ev.modifiers.ctrl then
			repl.PasteText()
		elseif #ev.key == 1 then
			repl.DeleteSelection()
			repl.input_buffer = repl.input_buffer:utf8_sub(1, repl.input_cursor - 1) .. ev.key .. repl.input_buffer:utf8_sub(repl.input_cursor)
			repl.input_cursor = repl.input_cursor + 1
			-- Auto-scroll to show cursor if needed
			local w = repl.term and repl.term:GetSize() or 80 -- Default width for tests
			local cursor_wrapped_line = get_wrapped_line_for_cursor(repl.input_buffer, repl.input_cursor, w)
			-- Calculate total wrapped lines
			local input_lines = {}

			for line in (repl.input_buffer .. "\n"):gmatch("(.-)\n") do
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
	-- Split input into lines
	local input_lines = {}

	for line in (repl.input_buffer .. "\n"):gmatch("(.-)\n") do
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
	local sel_start, sel_stop = repl.GetSelection()
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
	local cursor_line, cursor_col = get_cursor_pos(repl.input_buffer, repl.input_cursor)
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
