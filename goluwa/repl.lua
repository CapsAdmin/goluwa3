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
	needs_redraw = true,
	clipboard = "",
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

	return false
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
	repl.needs_redraw = true
	local old_cursor = repl.input_cursor

	if ev.key == "enter" then
		if ev.modifiers.ctrl then
			repl.input_buffer = repl.input_buffer:sub(1, repl.input_cursor - 1) .. "\n" .. repl.input_buffer:sub(repl.input_cursor)
			repl.input_cursor = repl.input_cursor + 1
		else
			if repl.input_buffer == "exit" then
				system.ShutDown(0)
				return
			end

			logn("> " .. repl.input_buffer)

			if repl.input_buffer ~= "" then
				table.insert(repl.history, repl.input_buffer)
				repl.history_index = #repl.history + 1
				repl.InputLua(repl.input_buffer)
			end

			repl.input_buffer = ""
			repl.input_cursor = 1
			repl.scroll_offset = 0
			repl.selection_start = nil
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
			repl.input_cursor = 1
		elseif ev.key == "end" then
			repl.input_cursor = #repl.input_buffer + 1
		end

		if ev.modifiers.shift then
			if not repl.selection_start then repl.selection_start = old_cursor end
		else
			repl.selection_start = nil
		end
	elseif ev.key == "up" then
		if repl.history_index > 1 then
			repl.history_index = repl.history_index - 1
			repl.input_buffer = repl.history[repl.history_index]
			repl.input_cursor = #repl.input_buffer + 1
			repl.selection_start = nil
		end
	elseif ev.key == "down" then
		if repl.history_index < #repl.history then
			repl.history_index = repl.history_index + 1
			repl.input_buffer = repl.history[repl.history_index]
			repl.input_cursor = #repl.input_buffer + 1
			repl.selection_start = nil
		else
			repl.history_index = #repl.history + 1
			repl.input_buffer = ""
			repl.input_cursor = 1
			repl.selection_start = nil
		end
	elseif ev.key == "pageup" then
		repl.scroll_offset = repl.scroll_offset + 10
	elseif ev.key == "pagedown" then
		repl.scroll_offset = math.max(0, repl.scroll_offset - 10)
	elseif ev.key == "c" and ev.modifiers.ctrl then
		repl.CopyText()
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
	-- Split input into lines
	local input_lines = {}

	for line in (repl.input_buffer .. "\n"):gmatch("(.-)\n") do
		table.insert(input_lines, line)
	end

	-- Draw output
	local max_output_h = h - 1 - #input_lines
	local total_lines = #repl.output_lines
	local start_idx = math.max(1, total_lines - max_output_h + 1 - repl.scroll_offset)

	for i = 0, max_output_h - 1 do
		local line = repl.output_lines[start_idx + i]

		if line then
			-- Truncate line if too long
			if #line > w then line = line:sub(1, w) end

			term:WriteStringToScreen(1, i + 1, line)
		end
	end

	-- Draw separator
	local sep = string.rep("-", w)

	if repl.scroll_offset > 0 then
		local scroll_text = " SCROLL: " .. repl.scroll_offset .. " "
		sep = scroll_text .. string.rep("-", math.max(0, w - #scroll_text))
	end

	term:WriteStringToScreen(1, h - #input_lines, sep)
	-- Draw input
	local sel_start, sel_stop = repl.GetSelection()
	local current_char_idx = 1

	for i, line in ipairs(input_lines) do
		local prefix = i == 1 and "> " or "  "
		local y = h - #input_lines + i
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
	term:SetCaretPosition(math.min(w, 3 + cursor_col - 1), h - #input_lines + cursor_line)
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
