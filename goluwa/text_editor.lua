local prototype = require("prototype")
local clipboard = require("bindings.clipboard")
local TextBuffer

do
	local utf8 = require("utf8")
	TextBuffer = prototype.CreateTemplate("text_buffer")

	function TextBuffer.New(str) end

	TextBuffer:Register()
end

local TextEditor = prototype.CreateTemplate("text_editor")
TextEditor:GetSet("Text", "")
TextEditor:GetSet("Cursor", 1)
TextEditor:GetSet("SelectionStart", nil)
TextEditor:GetSet("ShiftDown", false)
TextEditor:GetSet("ControlDown", false)
TextEditor:GetSet("Multiline", true)
TextEditor:GetSet("PreserveTabsOnEnter", true)
TextEditor:GetSet("WrapWidth", nil)

function TextEditor.New(text)
	local self = TextEditor:CreateObject(
		{
			Text = text or "",
			Cursor = 1,
			undo_stack = {},
			redo_stack = {},
			ClipboardState = nil,
		}
	)
	return self
end

function TextEditor:SetClipboard(str)
	self.ClipboardState = str
	clipboard.Set(str)
end

function TextEditor:GetClipboard()
	return clipboard.Get() or self.ClipboardState
end

function TextEditor:SetText(text)
	self.Text = text
	self.Cursor = math.min(self.Cursor, utf8.length(text) + 1)

	if self.OnTextChanged then self:OnTextChanged(text) end
end

function TextEditor:GetSelection()
	if not self.SelectionStart then return nil end

	local start = math.min(self.SelectionStart, self.Cursor)
	local stop = math.max(self.SelectionStart, self.Cursor)
	return start, stop
end

function TextEditor:DeleteSelection()
	local start, stop = self:GetSelection()

	if start then
		self:SaveUndoState()
		local text = self.Text
		self.Text = utf8.sub(text, 1, start - 1) .. utf8.sub(text, stop)
		self.Cursor = start
		self.SelectionStart = nil

		if self.OnTextChanged then self:OnTextChanged(self.Text) end

		return true
	end

	return false
end

function TextEditor:InsertString(str)
	self:DeleteSelection()
	local text = self.Text
	local cursor = self.Cursor
	self.Text = utf8.sub(text, 1, cursor - 1) .. str .. utf8.sub(text, cursor)
	self.Cursor = cursor + utf8.length(str)

	if self.OnTextChanged then self:OnTextChanged(self.Text) end
end

function TextEditor:Backspace()
	if not self:DeleteSelection() then
		local cursor = self.Cursor

		if cursor > 1 then
			if self.ControlDown then
				local new_pos = self:MoveWord(cursor, -1)
				self.Text = utf8.sub(self.Text, 1, new_pos - 1) .. utf8.sub(self.Text, cursor)
				self.Cursor = new_pos
			else
				self.Text = utf8.sub(self.Text, 1, cursor - 2) .. utf8.sub(self.Text, cursor)
				self.Cursor = cursor - 1
			end

			if self.OnTextChanged then self:OnTextChanged(self.Text) end
		end
	end
end

function TextEditor:Delete()
	if not self:DeleteSelection() then
		local cursor = self.Cursor

		if cursor <= utf8.length(self.Text) then
			if self.ControlDown then
				local new_pos = self:MoveWord(cursor, 1)
				self.Text = utf8.sub(self.Text, 1, cursor - 1) .. utf8.sub(self.Text, new_pos)
			else
				self.Text = utf8.sub(self.Text, 1, cursor - 1) .. utf8.sub(self.Text, cursor + 1)
			end

			if self.OnTextChanged then self:OnTextChanged(self.Text) end
		end
	end
end

local function get_char_class(char)
	if not char then return "none" end

	if char:match("[%w_]") then return "word" end

	if char:match("%s") then return "space" end

	return "other"
end

function TextEditor:MoveWord(pos, dir)
	local buffer = self.Text
	local len = utf8.length(buffer)
	local new_pos = pos

	if dir == -1 then
		if new_pos <= 1 then return 1 end

		while
			new_pos > 1 and
			get_char_class(utf8.sub(buffer, new_pos - 1, new_pos - 1)) == "space"
		do
			new_pos = new_pos - 1
		end

		if new_pos <= 1 then return 1 end

		new_pos = new_pos - 1
		local class = get_char_class(utf8.sub(buffer, new_pos, new_pos))

		while
			new_pos > 1 and
			get_char_class(utf8.sub(buffer, new_pos - 1, new_pos - 1)) == class
		do
			new_pos = new_pos - 1
		end
	else
		while new_pos <= len and get_char_class(utf8.sub(buffer, new_pos, new_pos)) == "space" do
			new_pos = new_pos + 1
		end

		if new_pos > len then return len + 1 end

		local class = get_char_class(utf8.sub(buffer, new_pos, new_pos))

		while new_pos <= len and get_char_class(utf8.sub(buffer, new_pos, new_pos)) == class do
			new_pos = new_pos + 1
		end
	end

	return new_pos
end

function TextEditor:OnCharInput(char)
	self:InsertString(char)
end

function TextEditor:OnKeyInput(key)
	local old_cursor = self.Cursor

	if key == "left" then
		if self.ControlDown then
			self.Cursor = self:MoveWord(self.Cursor, -1)
		else
			self.Cursor = math.max(1, self.Cursor - 1)
		end
	elseif key == "right" then
		if self.ControlDown then
			self.Cursor = self:MoveWord(self.Cursor, 1)
		else
			self.Cursor = math.min(utf8.length(self.Text) + 1, self.Cursor + 1)
		end
	elseif key == "home" then
		local pos = self.Cursor

		while pos > 1 and utf8.sub(self.Text, pos - 1, pos - 1) ~= "\n" do
			pos = pos - 1
		end

		self.Cursor = pos
	elseif key == "end" then
		local pos = self.Cursor
		local len = utf8.length(self.Text)

		while pos <= len and utf8.sub(self.Text, pos, pos) ~= "\n" do
			pos = pos + 1
		end

		self.Cursor = pos
	elseif key == "up" and self.Multiline then
		if self.OnMoveUp then
			self.OnMoveUp(self)
		else
			-- Fallback: move to previous line same column
			local line, col = self:GetVisualLineCol()

			if line > 1 then self:SetVisualLineCol(line - 1, col) end
		end
	elseif key == "down" and self.Multiline then
		if self.OnMoveDown then
			self.OnMoveDown(self)
		else
			-- Fallback: move to next line same column
			local line, col = self:GetVisualLineCol()
			local line_count = self:GetVisualLineCount()

			if line < line_count then self:SetVisualLineCol(line + 1, col) end
		end
	elseif key == "pageup" and self.Multiline then
		if self.OnPageUp then
			self.OnPageUp(self)
		else
			local line, col = self:GetVisualLineCol()
			self:SetVisualLineCol(math.max(1, line - 10), col)
		end
	elseif key == "pagedown" and self.Multiline then
		if self.OnPageDown then
			self.OnPageDown(self)
		else
			local line, col = self:GetVisualLineCol()
			local line_count = self:GetVisualLineCount()
			self:SetVisualLineCol(math.min(line_count, line + 10), col)
		end
	elseif key == "backspace" then
		self:Backspace()
	elseif key == "delete" then
		self:Delete()
	elseif key == "enter" and self.Multiline then
		self:Enter()
	elseif key == "tab" then
		self:Indent(self.ShiftDown)
	elseif self.ControlDown then
		if key == "a" then
			self:SelectAll()
		elseif key == "c" then
			self:Copy()
		elseif key == "x" then
			self:Cut()
		elseif key == "v" then
			local str = self:GetClipboard()

			if str then self:Paste(str) end
		elseif key == "z" then
			if self.ShiftDown then self:Redo() else self:Undo() end
		elseif key == "y" then
			self:Redo()
		elseif key == "d" then
			self:DuplicateLine()
		end
	end

	if self.ShiftDown then
		local is_navigation = key == "left" or
			key == "right" or
			key == "up" or
			key == "down" or
			key == "home" or
			key == "end" or
			key == "pageup" or
			key == "pagedown"

		if is_navigation and not self.SelectionStart then
			self.SelectionStart = old_cursor
		end
	else
		if
			key == "left" or
			key == "right" or
			key == "up" or
			key == "down" or
			key == "home" or
			key == "end" or
			key == "pageup" or
			key == "pagedown"
		then
			self.SelectionStart = nil
		end
	end
end

function TextEditor:GetVisualLineCol(pos)
	pos = pos or self.Cursor

	if not self.WrapWidth then return self:GetCursorLineCol(pos) end

	local logical_line, logical_col = self:GetCursorLineCol(pos)
	local lines = self.Text:split("\n")
	local vline = 0

	for i = 1, logical_line - 1 do
		local line_len = utf8.length(lines[i] or "")
		vline = vline + math.max(1, math.ceil(line_len / self.WrapWidth))
	end

	local current_line_vlines = math.floor((logical_col - 1) / self.WrapWidth)
	vline = vline + current_line_vlines + 1
	local vcol = ((logical_col - 1) % self.WrapWidth) + 1
	return vline, vcol
end

function TextEditor:SetVisualLineCol(target_line, target_col)
	if not self.WrapWidth then
		return self:SetCursorLineCol(target_line, target_col)
	end

	local lines = self.Text:split("\n")
	local current_vline = 0

	for i = 1, #lines do
		local line_text = lines[i]
		local line_len = utf8.length(line_text)
		local vlines_in_this_logical_line = math.max(1, math.ceil(line_len / self.WrapWidth))

		if target_line <= current_vline + vlines_in_this_logical_line then
			local vline_in_logical = target_line - current_vline
			local logical_col = (vline_in_logical - 1) * self.WrapWidth + target_col
			logical_col = math.min(logical_col, line_len + 1)
			self:SetCursorLineCol(i, logical_col)
			return
		end

		current_vline = current_vline + vlines_in_this_logical_line
	end

	self.Cursor = utf8.length(self.Text) + 1
end

function TextEditor:GetVisualLineCount()
	if not self.WrapWidth then return select(2, self.Text:gsub("\n", "")) + 1 end

	local lines = self.Text:split("\n")
	local count = 0

	for i = 1, #lines do
		count = count + math.max(1, math.ceil(utf8.length(lines[i]) / self.WrapWidth))
	end

	return count
end

function TextEditor:SetCursorLineCol(target_line, target_col)
	local line = 1
	local col = 1
	local pos = 1
	local len = utf8.length(self.Text)

	while pos <= len do
		if line == target_line then
			if col == target_col then
				self.Cursor = pos
				return
			end
		end

		if utf8.sub(self.Text, pos, pos) == "\n" then
			if line == target_line then
				self.Cursor = pos
				return
			end

			line = line + 1
			col = 1
		else
			col = col + 1
		end

		pos = pos + 1
	end

	if line == target_line then self.Cursor = pos end
end

function TextEditor:SelectAll()
	self.SelectionStart = 1
	self.Cursor = utf8.length(self.Text) + 1
end

function TextEditor:Copy()
	local start, stop = self:GetSelection()

	if start then
		local str = utf8.sub(self.Text, start, stop - 1)
		self:SetClipboard(str)
		return str
	end
end

function TextEditor:Cut()
	local str = self:Copy()

	if str then self:DeleteSelection() end

	return str
end

function TextEditor:Paste(str)
	self:InsertString(str)
end

function TextEditor:SaveUndoState()
	table.insert(self.undo_stack, {text = self.Text, cursor = self.Cursor})

	if #self.undo_stack > 100 then table.remove(self.undo_stack, 1) end

	self.redo_stack = {}
end

function TextEditor:Undo()
	local state = table.remove(self.undo_stack)

	if state then
		table.insert(self.redo_stack, {text = self.Text, cursor = self.Cursor})
		self.Text = state.text
		self.Cursor = state.cursor

		if self.OnTextChanged then self:OnTextChanged(self.Text) end
	end
end

function TextEditor:Redo()
	local state = table.remove(self.redo_stack)

	if state then
		table.insert(self.undo_stack, {text = self.Text, cursor = self.Cursor})
		self.Text = state.text
		self.Cursor = state.cursor

		if self.OnTextChanged then self:OnTextChanged(self.Text) end
	end
end

function TextEditor:Enter()
	self:SaveUndoState()
	self:DeleteSelection()

	if self.PreserveTabsOnEnter then
		local line, col = self:GetCursorLineCol()
		local lines = self.Text:split("\n")
		local current_line_text = lines[line] or ""
		local tabs = current_line_text:match("^([\t]*)") or ""
		self:InsertString("\n" .. tabs)
	else
		self:InsertString("\n")
	end
end

function TextEditor:SelectWord()
	local old_cursor = self.Cursor
	self.Cursor = self:MoveWord(old_cursor, -1)
	self.SelectionStart = self.Cursor
	self.Cursor = self:MoveWord(old_cursor, 1)
end

function TextEditor:SelectLine()
	local line, col = self:GetCursorLineCol()
	self:SetCursorLineCol(line, 1)
	self.SelectionStart = self.Cursor
	local len = utf8.length(self.Text)

	while self.Cursor <= len and utf8.sub(self.Text, self.Cursor, self.Cursor) ~= "\n" do
		self.Cursor = self.Cursor + 1
	end
end

function TextEditor:DuplicateLine()
	local line, col = self:GetCursorLineCol()
	local pos = self.Cursor
	local line_start = pos

	while line_start > 1 and utf8.sub(self.Text, line_start - 1, line_start - 1) ~= "\n" do
		line_start = line_start - 1
	end

	local line_end = pos
	local len = utf8.length(self.Text)

	while line_end <= len and utf8.sub(self.Text, line_end, line_end) ~= "\n" do
		line_end = line_end + 1
	end

	local line_content = utf8.sub(self.Text, line_start, line_end - 1)
	self:SaveUndoState()
	self.Text = utf8.sub(self.Text, 1, line_end - 1) .. "\n" .. line_content .. utf8.sub(self.Text, line_end)
	self.Cursor = line_end + 1
	self.SelectionStart = nil

	if self.OnTextChanged then self:OnTextChanged(self.Text) end
end

function TextEditor:Indent(back)
	local start, stop = self:GetSelection()

	if not start or not utf8.sub(self.Text, start, stop - 1):find("\n") then
		if back then
			local line, col = self:GetCursorLineCol()
			local pos = self.Cursor

			if col > 1 and utf8.sub(self.Text, pos - 1, pos - 1) == "\t" then
				self:SaveUndoState()
				self.Text = utf8.sub(self.Text, 1, pos - 2) .. utf8.sub(self.Text, pos)
				self.Cursor = pos - 1

				if self.OnTextChanged then self:OnTextChanged(self.Text) end
			end
		else
			self:InsertString("\t")
		end

		return
	end

	-- Multiline indentation
	self:SaveUndoState()
	-- Expand selection to full lines
	local start_line = select(1, self:GetCursorLineCol(start))
	local stop_line = select(1, self:GetCursorLineCol(stop - 1))
	local lines = self.Text:split("\n")

	for i = start_line, stop_line do
		if back then
			if lines[i]:sub(1, 1) == "\t" then lines[i] = lines[i]:sub(2) end
		else
			lines[i] = "\t" .. lines[i]
		end
	end

	self.Text = table.concat(lines, "\n")
	-- Re-calculate selection and cursor
	self:SetCursorLineCol(start_line, 1)
	self.SelectionStart = self.Cursor
	self:SetCursorLineCol(stop_line, utf8.length(lines[stop_line]) + 1)

	if self.OnTextChanged then self:OnTextChanged(self.Text) end
end

function TextEditor:GetCursorLineCol(pos)
	pos = pos or self.Cursor
	local line = 1
	local col = 1

	for i = 1, pos - 1 do
		if utf8.sub(self.Text, i, i) == "\n" then
			line = line + 1
			col = 1
		else
			col = col + 1
		end
	end

	return line, col
end

return TextEditor:Register()
