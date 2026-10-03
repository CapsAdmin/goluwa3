local T = import("test/environment.lua")
local sequence_editor = import("goluwa/sequence_editor.lua")

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
	T(editor.Cursor)["=="](6)
	editor:OnKeyInput("right")
	T(editor.Cursor)["=="](12)
	editor:OnKeyInput("left")
	T(editor.Cursor)["=="](7)
	editor:OnKeyInput("left")
	T(editor.Cursor)["=="](1)
end)

T.Test("sequence_editor ctrl backspace", function()
	local editor = sequence_editor.New("hello world test")
	editor.Cursor = 12
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
	editor.Cursor = 5
	editor:OnKeyInput("end")
	T(editor.Cursor)["=="](9)
	editor:OnKeyInput("home")
	T(editor.Cursor)["=="](1)
	editor.Cursor = 15
	editor:OnKeyInput("end")
	T(editor.Cursor)["=="](18)
	editor:OnKeyInput("home")
	T(editor.Cursor)["=="](10)
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
	editor:OnKeyInput("z")
	T(editor:GetBuffer():GetText())["=="]("hello")
	editor:SetShiftDown(true)
	editor:OnKeyInput("z")
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
	editor.Cursor = 8
	editor:SelectWord()
	local start, stop = editor:GetSelection()
	T(start)["=="](7)
	T(stop)["=="](12)
	editor = sequence_editor.New("line one\nline two")
	editor.Cursor = 5
	editor:SelectLine()
	start, stop = editor:GetSelection()
	T(start)["=="](1)
	T(stop)["=="](9)
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
	editor:OnKeyInput("a")
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
	editor.Cursor = 1
	editor.SelectionStart = 6
	editor:Copy()
	T(editor:GetClipboard())["=="]("hello")
	editor:SetText("")
	editor.Cursor = 1
	editor:Paste(editor:GetClipboard())
	T(editor:GetBuffer():GetText())["=="]("hello")
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
	editor:OnKeyInput("v")
	T(editor:GetBuffer():GetText())["=="]("mock")
end)

T.Test("sequence_editor wrapping", function()
	local editor = sequence_editor.New("1234567890")
	editor:SetWrapWidth(5)
	editor.Cursor = 1
	local line, col = editor:GetVisualLineCol()
	T(line)["=="](1)
	T(col)["=="](1)
	editor.Cursor = 6
	line, col = editor:GetVisualLineCol()
	T(line)["=="](2)
	T(col)["=="](1)
	editor:OnKeyInput("up")
	T(editor.Cursor)["=="](1)
	editor:OnKeyInput("down")
	T(editor.Cursor)["=="](6)
	editor:SetText("abc\ndefghi")
	editor:SetWrapWidth(3)
	editor.Cursor = 5
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
	editor.Cursor = 1
	editor:SetVisualLineCol(3, 1)
	T(editor.Cursor)["=="](11)
	editor:SetVisualLineCol(3, 5)
	T(editor.Cursor)["=="](14)
	T(editor:GetVisualLineCount())["=="](3)
	editor:SetText("a\n\nb")
	editor:SetWrapWidth(5)
	T(editor:GetVisualLineCount())["=="](3)
	editor.Cursor = 3
	local vline, vcol = editor:GetVisualLineCol()
	T(vline)["=="](2)
	T(vcol)["=="](1)
	editor:SetText("hello")
	editor:SetWrapWidth(1)
	T(editor:GetVisualLineCount())["=="](5)
end)
