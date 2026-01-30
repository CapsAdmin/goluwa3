local prototype = require("prototype")
local clipboard = require("bindings.clipboard")
local SequenceBuffer = require("sequence_buffer")
local SequenceEditor = prototype.CreateTemplate("sequence_editor")
SequenceEditor:GetSet("Buffer", nil)
SequenceEditor:GetSet("Cursor", 1)
SequenceEditor:GetSet("SelectionStart", nil)
SequenceEditor:GetSet("ShiftDown", false)
SequenceEditor:GetSet("ControlDown", false)
SequenceEditor:GetSet("Multiline", true)
SequenceEditor:GetSet("PreserveTabsOnEnter", true)
SequenceEditor:GetSet("WrapWidth", nil)

function SequenceEditor.New(buffer)
	if type(buffer) == "string" then buffer = SequenceBuffer.New(buffer) end

	local self = SequenceEditor:CreateObject(
		{
			Buffer = buffer or SequenceBuffer.New(""),
			Cursor = 1,
			undo_stack = {},
			redo_stack = {},
			ClipboardState = nil,
		}
	)
	return self
end

function SequenceEditor:SetClipboard(str)
	self.ClipboardState = str
	clipboard.Set(str)
end

function SequenceEditor:GetClipboard()
	return clipboard.Get() or self.ClipboardState
end

function SequenceEditor:SetData(data)
	self.Buffer:SetText(data)
	self.Cursor = math.min(self.Cursor, self.Buffer:GetLength() + 1)

	if self.OnChanged then
		self:OnChanged(data)
	elseif self.OnTextChanged then
		self:OnTextChanged(data)
	end
end

function SequenceEditor:SetText(text)
	return self:SetData(text)
end

function SequenceEditor:GetData()
	return self.Buffer:GetText()
end

function SequenceEditor:GetText()
	return self:GetData()
end

function SequenceEditor:GetSelection()
	if not self.SelectionStart then return nil end

	local start = math.min(self.SelectionStart, self.Cursor)
	local stop = math.max(self.SelectionStart, self.Cursor)
	return start, stop
end

function SequenceEditor:NotifyChanged()
	if self.OnChanged then
		self:OnChanged(self.Buffer:GetText())
	elseif self.OnTextChanged then
		self:OnTextChanged(self.Buffer:GetText())
	end
end

function SequenceEditor:DeleteSelection()
	local start, stop = self:GetSelection()

	if start then
		self:SaveUndoState()
		self.Buffer:RemoveRange(start, stop)
		self.Cursor = start
		self.SelectionStart = nil
		self:NotifyChanged()
		return true
	end

	return false
end

function SequenceEditor:Insert(data)
	self:DeleteSelection()
	local cursor = self.Cursor
	local length = self.Buffer:Insert(cursor, data)
	self.Cursor = cursor + length
	self:NotifyChanged()
end

function SequenceEditor:InsertString(str)
	return self:Insert(str)
end

function SequenceEditor:Backspace()
	if not self:DeleteSelection() then
		local cursor = self.Cursor

		if cursor > 1 then
			if self.ControlDown then
				local new_pos = self.Buffer:GetNextWordBoundary(cursor, -1)
				self.Buffer:RemoveRange(new_pos, cursor)
				self.Cursor = new_pos
			else
				self.Buffer:RemoveRange(cursor - 1, cursor)
				self.Cursor = cursor - 1
			end

			self:NotifyChanged()
		end
	end
end

function SequenceEditor:Delete()
	if not self:DeleteSelection() then
		local cursor = self.Cursor

		if cursor <= self.Buffer:GetLength() then
			if self.ControlDown then
				local new_pos = self.Buffer:GetNextWordBoundary(cursor, 1)
				self.Buffer:RemoveRange(cursor, new_pos)
			else
				self.Buffer:RemoveRange(cursor, cursor + 1)
			end

			self:NotifyChanged()
		end
	end
end

function SequenceEditor:MoveWord(pos, dir)
	return self.Buffer:GetNextWordBoundary(pos, dir)
end

function SequenceEditor:OnCharInput(char)
	self:Insert(char)
end

function SequenceEditor:OnKeyInput(key)
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
			self.Cursor = math.min(self.Buffer:GetLength() + 1, self.Cursor + 1)
		end
	elseif key == "home" then
		self.Cursor = self.Buffer:GetLineStart(self.Cursor)
	elseif key == "end" then
		self.Cursor = self.Buffer:GetLineEnd(self.Cursor)
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

function SequenceEditor:GetVisualLineCol(pos)
	pos = pos or self.Cursor

	if not self.WrapWidth then return self:GetCursorLineCol(pos) end

	local logical_line, logical_col = self:GetCursorLineCol(pos)
	local lines = self.Buffer:GetLines()
	local vline = 0

	for i = 1, logical_line - 1 do
		local line_len = self.Buffer:GetLength(lines[i] or "")
		vline = vline + math.max(1, math.ceil(line_len / self.WrapWidth))
	end

	local current_line_vlines = math.floor((logical_col - 1) / self.WrapWidth)
	vline = vline + current_line_vlines + 1
	local vcol = ((logical_col - 1) % self.WrapWidth) + 1
	return vline, vcol
end

function SequenceEditor:SetVisualLineCol(target_line, target_col)
	if not self.WrapWidth then
		return self:SetCursorLineCol(target_line, target_col)
	end

	local lines = self.Buffer:GetLines()
	local current_vline = 0

	for i = 1, #lines do
		local line_text = lines[i]
		local line_len = self.Buffer:GetLength(line_text)
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

	self.Cursor = self.Buffer:GetLength() + 1
end

function SequenceEditor:GetVisualLineCount()
	if not self.WrapWidth then return self.Buffer:GetLineCount() end

	local lines = self.Buffer:GetLines()
	local count = 0

	for i = 1, #lines do
		count = count + math.max(1, math.ceil(self.Buffer:GetLength(lines[i]) / self.WrapWidth))
	end

	return count
end

function SequenceEditor:SetCursorLineCol(target_line, target_col)
	self.Cursor = self.Buffer:GetPosByLineCol(target_line, target_col)
end

function SequenceEditor:SelectAll()
	self.SelectionStart = 1
	self.Cursor = self.Buffer:GetLength() + 1
end

function SequenceEditor:Copy()
	local start, stop = self:GetSelection()

	if start then
		local str = self.Buffer:Sub(start, stop - 1)
		self:SetClipboard(str)
		return str
	end
end

function SequenceEditor:Cut()
	local str = self:Copy()

	if str then self:DeleteSelection() end

	return str
end

function SequenceEditor:Paste(str)
	self:Insert(str)
end

function SequenceEditor:SaveUndoState()
	table.insert(self.undo_stack, {text = self.Buffer:GetText(), cursor = self.Cursor})

	if #self.undo_stack > 100 then table.remove(self.undo_stack, 1) end

	self.redo_stack = {}
end

function SequenceEditor:Undo()
	local state = table.remove(self.undo_stack)

	if state then
		table.insert(self.redo_stack, {text = self.Buffer:GetText(), cursor = self.Cursor})
		self.Buffer:SetText(state.text)
		self.Cursor = state.cursor
		self:NotifyChanged()
	end
end

function SequenceEditor:Redo()
	local state = table.remove(self.redo_stack)

	if state then
		table.insert(self.undo_stack, {text = self.Buffer:GetText(), cursor = self.Cursor})
		self.Buffer:SetText(state.text)
		self.Cursor = state.cursor
		self:NotifyChanged()
	end
end

function SequenceEditor:Enter()
	self:SaveUndoState()
	self:DeleteSelection()
	local newline = self.Buffer:GetNewline()

	if self.PreserveTabsOnEnter then
		local line, col = self:GetCursorLineCol()
		local tabs = self.Buffer:GetIndentation(line)
		self:Insert(newline)
		self:Insert(tabs)
	else
		self:Insert(newline)
	end
end

function SequenceEditor:SelectWord()
	local old_cursor = self.Cursor
	self.Cursor = self.Buffer:GetNextWordBoundary(old_cursor, -1)
	self.SelectionStart = self.Cursor
	self.Cursor = self.Buffer:GetNextWordBoundary(old_cursor, 1)
end

function SequenceEditor:SelectLine()
	local line, col = self:GetCursorLineCol()
	self:SetCursorLineCol(line, 1)
	self.SelectionStart = self.Cursor
	self.Cursor = self.Buffer:GetLineEnd(self.Cursor)
end

function SequenceEditor:DuplicateLine()
	local line, col = self:GetCursorLineCol()
	local line_start = self.Buffer:GetLineStart(self.Cursor)
	local line_end = self.Buffer:GetLineEnd(self.Cursor)
	local line_content = self.Buffer:Sub(line_start, line_end - 1)
	self:SaveUndoState()
	self.Buffer:Insert(line_end, self.Buffer:GetNewline())
	self.Buffer:Insert(line_end + 1, line_content)
	self.Cursor = line_end + 1
	self.SelectionStart = nil
	self:NotifyChanged()
end

function SequenceEditor:Indent(back)
	local start, stop = self:GetSelection()
	local start_line = start and select(1, self:GetCursorLineCol(start))
	local stop_line = stop and select(1, self:GetCursorLineCol(stop - 1))

	if not start or start_line == stop_line then
		if back then
			local line, col = self:GetCursorLineCol()
			local pos = self.Cursor
			local tab = self.Buffer:GetTab()

			if col > 1 and self.Buffer:Sub(pos - 1, pos - 1) == tab then
				self:SaveUndoState()
				self.Buffer:RemoveRange(pos - 1, pos)
				self.Cursor = pos - 1
				self:NotifyChanged()
			end
		else
			self:Insert(self.Buffer:GetTab())
		end

		return
	end

	-- Multiline indentation
	self:SaveUndoState()

	-- Expand selection to full lines
	for i = start_line, stop_line do
		self.Buffer:IndentLine(i, back)
	end

	-- Re-calculate selection and cursor
	self:SetCursorLineCol(start_line, 1)
	self.SelectionStart = self.Cursor
	self:SetCursorLineCol(stop_line, self.Buffer:GetLength(self.Buffer:GetLine(stop_line)) + 1)
	self:NotifyChanged()
end

function SequenceEditor:GetCursorLineCol(pos)
	return self.Buffer:GetLineColByPos(pos or self.Cursor)
end

return SequenceEditor:Register()
