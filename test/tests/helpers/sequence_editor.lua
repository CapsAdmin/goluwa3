local T = require("test.environment")
local sequence_editor = require("sequence_editor")

T.Test("sequence_editor basics", function()
	local editor = sequence_editor.New("hello world")
	T(editor:GetBuffer():GetText())["=="]("hello world")
	T(editor.Cursor)["=="](1)
	editor.Cursor = 7
	editor:InsertString("awesome ")
	T(editor:GetBuffer():GetText())["=="]("hello awesome world")
	T(editor.Cursor)["=="](15)
	editor:Backspace()
	T(editor:GetBuffer():GetText())["=="]("hello awesomeworld")
	T(editor.Cursor)["=="](14)
end)

T.Test("sequence_editor selection", function()
	local editor = sequence_editor.New("hello world")
	editor.Cursor = 1
	editor.SelectionStart = 7
	local start, stop = editor:GetSelection()
	T(start)["=="](1)
	T(stop)["=="](7)
	editor:DeleteSelection()
	T(editor:GetBuffer():GetText())["=="]("world")
	T(editor.Cursor)["=="](1)
end)

T.Test("sequence_editor multiline", function()
	local editor = sequence_editor.New("line 1\nline 2\nline 3")
	editor.Cursor = 10
	local line, col = editor:GetCursorLineCol()
	T(line)["=="](2)
	T(col)["=="](3)
	editor:SetCursorLineCol(3, 1)
	T(editor.Cursor)["=="](15)
end)

T.Test("sequence_editor word movement", function()
	local editor = sequence_editor.New("hello world  test")
	editor.Cursor = 1
	editor.Cursor = editor:MoveWord(editor.Cursor, 1)
	T(editor.Cursor)["=="](6)
	editor.Cursor = editor:MoveWord(editor.Cursor, 1)
	T(editor.Cursor)["=="](12)
	editor.Cursor = editor:MoveWord(editor.Cursor, -1)
	T(editor.Cursor)["=="](7)
end)

T.Test("sequence_editor ctrl movement", function()
	local editor = sequence_editor.New("hello world test")
	editor.Cursor = 1
	editor:SetControlDown(true)
	editor:OnKeyInput("right")
	T(editor.Cursor)["=="](6) -- "hello| "
	editor:OnKeyInput("right")
	T(editor.Cursor)["=="](12) -- "hello world| "
	editor:OnKeyInput("left")
	T(editor.Cursor)["=="](7) -- "hello |world"
	editor:OnKeyInput("left")
	T(editor.Cursor)["=="](1) -- "|hello world"
end)

T.Test("sequence_editor ctrl backspace", function()
	local editor = sequence_editor.New("hello world test")
	editor.Cursor = 12 -- "hello world| test"
	editor:SetControlDown(true)
	editor:OnKeyInput("backspace")
	T(editor:GetBuffer():GetText())["=="]("hello  test")
	T(editor.Cursor)["=="](7)
	editor:OnKeyInput("backspace")
	T(editor:GetBuffer():GetText())["=="](" test")
	T(editor.Cursor)["=="](1)
end)

T.Test("sequence_editor home end", function()
	local editor = sequence_editor.New("line one\nline two")
	editor.Cursor = 5 -- "line| one"
	editor:OnKeyInput("end")
	T(editor.Cursor)["=="](9) -- end of first line
	editor:OnKeyInput("home")
	T(editor.Cursor)["=="](1) -- start of first line
	editor.Cursor = 15 -- "line t|wo"
	editor:OnKeyInput("end")
	T(editor.Cursor)["=="](18) -- end of second line
	editor:OnKeyInput("home")
	T(editor.Cursor)["=="](10) -- start of second line
end)

T.Test("sequence_editor selection with shift", function()
	local editor = sequence_editor.New("hello world")
	editor.Cursor = 1
	editor:SetShiftDown(true)
	editor:OnKeyInput("right")
	T(editor.Cursor)["=="](2)
	T(editor.SelectionStart)["=="](1)
	editor:OnKeyInput("right")
	T(editor.Cursor)["=="](3)
	T(editor.SelectionStart)["=="](1)
	editor:SetShiftDown(false)
	editor:OnKeyInput("left")
	T(editor.SelectionStart)["=="](nil)
end)

T.Test("sequence_editor undo", function()
	local editor = sequence_editor.New("hello")
	editor.Cursor = 6
	editor:SaveUndoState()
	editor:InsertString(" world")
	T(editor:GetBuffer():GetText())["=="]("hello world")
	editor:SetControlDown(true)
	editor:OnKeyInput("z")
	T(editor:GetBuffer():GetText())["=="]("hello")
	T(editor.Cursor)["=="](6)
	editor:OnKeyInput("y")
	T(editor:GetBuffer():GetText())["=="]("hello world")
	T(editor.Cursor)["=="](12)
	editor:OnKeyInput("z") -- undo
	T(editor:GetBuffer():GetText())["=="]("hello")
	editor:SetShiftDown(true)
	editor:OnKeyInput("z") -- redo via ctrl+shift+z
	T(editor:GetBuffer():GetText())["=="]("hello world")
end)

T.Test("sequence_editor page up down", function()
	local text = ""

	for i = 1, 30 do
		text = text .. "line " .. i .. "\n"
	end

	local editor = sequence_editor.New(text)
	editor:SetCursorLineCol(25, 1)
	editor:OnKeyInput("pageup")
	local line, col = editor:GetCursorLineCol()
	T(line)["=="](15)
	editor:OnKeyInput("pagedown")
	line, col = editor:GetCursorLineCol()
	T(line)["=="](25)
end)

T.Test("sequence_editor ctrl delete", function()
	local editor = sequence_editor.New("hello world test")
	editor.Cursor = 1
	editor:SetControlDown(true)
	editor:OnKeyInput("delete")
	T(editor:GetBuffer():GetText())["=="](" world test")
	T(editor.Cursor)["=="](1)
end)

T.Test("sequence_editor select word/line", function()
	local editor = sequence_editor.New("hello world test")
	editor.Cursor = 8 -- "hello w|orld test"
	editor:SelectWord()
	local start, stop = editor:GetSelection()
	T(start)["=="](7)
	T(stop)["=="](12) -- "world"
	editor = sequence_editor.New("line one\nline two")
	editor.Cursor = 5 -- "line| one"
	editor:SelectLine()
	start, stop = editor:GetSelection()
	T(start)["=="](1)
	T(stop)["=="](9) -- "line one"
end)

T.Test("sequence_editor duplicate line", function()
	local editor = sequence_editor.New("hello\nworld")
	editor.Cursor = 1
	editor:SetControlDown(true)
	editor:OnKeyInput("d")
	T(editor:GetBuffer():GetText())["=="]("hello\nhello\nworld")
end)

T.Test("sequence_editor indentation", function()
	local editor = sequence_editor.New("hello")
	editor:OnKeyInput("tab")
	T(editor:GetBuffer():GetText())["=="]("\thello")
	editor:SetShiftDown(true)
	editor:OnKeyInput("tab")
	T(editor:GetBuffer():GetText())["=="]("hello")
end)

T.Test("sequence_editor select all / char input", function()
	local editor = sequence_editor.New("hello")
	editor:OnKeyInput("a") -- This doesn't do anything because ControlDown is false
	T(editor:GetBuffer():GetText())["=="]("hello")
	editor:SetControlDown(true)
	editor:OnKeyInput("a")
	local start, stop = editor:GetSelection()
	T(start)["=="](1)
	T(stop)["=="](6)
	editor:SetControlDown(false)
	editor:OnCharInput("w")
	T(editor:GetBuffer():GetText())["=="]("w")
	T(editor.Cursor)["=="](2)
end)

T.Test("sequence_editor clipboard", function()
	local editor = sequence_editor.New("hello world")
	-- Test internal clipboard state tracking
	editor.Cursor = 1
	editor.SelectionStart = 6
	editor:Copy()
	T(editor:GetClipboard())["=="]("hello")
	editor:SetText("")
	editor.Cursor = 1
	editor:Paste(editor:GetClipboard())
	T(editor:GetBuffer():GetText())["=="]("hello")
	-- Test overriding clipboard
	local mock_clipboard = ""
	editor.SetClipboard = function(self, str)
		mock_clipboard = str
	end
	editor.GetClipboard = function(self)
		return mock_clipboard
	end
	editor:SetText("mock test")
	editor.Cursor = 1
	editor.SelectionStart = 5
	local ret = editor:Copy()
	T(ret)["=="]("mock")
	T(mock_clipboard)["=="]("mock")
	editor:SetText("")
	editor.Cursor = 1
	editor:SetControlDown(true)
	editor:OnKeyInput("v") -- Paste
	T(editor:GetBuffer():GetText())["=="]("mock")
end)

T.Test("sequence_editor wrapping", function()
	local editor = sequence_editor.New("1234567890")
	editor:SetWrapWidth(5)
	-- [[
	-- 12345
	-- 67890
	-- ]]
	editor.Cursor = 1 -- "1"
	local line, col = editor:GetVisualLineCol()
	T(line)["=="](1)
	T(col)["=="](1)
	editor.Cursor = 6 -- "6"
	line, col = editor:GetVisualLineCol()
	T(line)["=="](2)
	T(col)["=="](1)
	editor:OnKeyInput("up")
	T(editor.Cursor)["=="](1)
	editor:OnKeyInput("down")
	T(editor.Cursor)["=="](6)
	-- Test wrapping with real newlines
	editor:SetText("abc\ndefghi")
	editor:SetWrapWidth(3)
	-- [[
	-- abc
	-- def
	-- ghi
	-- ]]
	editor.Cursor = 5 -- "d"
	line, col = editor:GetVisualLineCol()
	T(line)["=="](2)
	T(col)["=="](1)
	editor:OnKeyInput("down")
	line, col = editor:GetVisualLineCol()
	T(line)["=="](3)
	T(col)["=="](1)
	T(editor:GetText():utf8_sub(editor.Cursor, editor.Cursor))["=="]("g")
end)

T.Test("sequence_editor wrapping edge cases", function()
	local editor = sequence_editor.New("1234567890123")
	editor:SetWrapWidth(5)
	-- [[
	-- 12345 (1)
	-- 67890 (2)
	-- 123   (3)
	-- ]]
	-- Test navigation to a shorter last line
	editor.Cursor = 1 -- line 1, col 1
	editor:SetVisualLineCol(3, 1) -- move to "1" in "123"
	T(editor.Cursor)["=="](11)
	editor:SetVisualLineCol(3, 5) -- move to col 5 in "123" (should clamp to end of string)
	T(editor.Cursor)["=="](14)
	-- Test multi-line wrap count
	T(editor:GetVisualLineCount())["=="](3)
	-- Test empty lines
	editor:SetText("a\n\nb")
	editor:SetWrapWidth(5)
	-- [[
	-- a (1)
	--   (2)
	-- b (3)
	-- ]]
	T(editor:GetVisualLineCount())["=="](3)
	editor.Cursor = 3 -- Positioned at the second newline (start of line 2)
	local vline, vcol = editor:GetVisualLineCol()
	T(vline)["=="](2)
	T(vcol)["=="](1)
	-- Test zero/small wrap width (should handle gracefully)
	editor:SetText("hello")
	editor:SetWrapWidth(1)
	-- [[
	-- h
	-- e
	-- l
	-- l
	-- o
	-- ]]
	T(editor:GetVisualLineCount())["=="](5)
end)
