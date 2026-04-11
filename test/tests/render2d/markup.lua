local T = import("test/environment.lua")
local MarkupBuffer = import("goluwa/render2d/markup_buffer.lua")
local Markup = import("goluwa/render2d/markup.lua")
local base_font = import("goluwa/render2d/fonts/base.lua")
local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")

T.Test("MarkupBuffer basic operations", function()
	local buffer = MarkupBuffer.New("hello world")
	T(buffer:GetText())["=="]("hello world")
	T(buffer:GetLength())["=="](11)
	buffer:Insert(12, "!")
	T(buffer:GetText())["=="]("hello world!")
	T(buffer:GetLength())["=="](12)
	buffer:RemoveRange(6, 12)
	T(buffer:GetText())["=="]("hello!")
	T(buffer:GetLength())["=="](6)
end)

T.Test("MarkupBuffer chunks", function()
	local buffer = MarkupBuffer.New()
	buffer:AddString("hello ")
	buffer:AddColor(Color(1, 0, 0, 1))
	buffer:AddString("red")
	buffer:AddTagStopper()
	T(buffer:GetText())["=="]("hello red")
	-- GetFullText should show tags if possible
	local full_text = buffer:GetFullText()
	T(full_text:find("<color=1,0,0,1>"))["~="](nil)
	T(full_text:find("red"))["~="](nil)
end)

T.Test("MarkupBuffer Insert and RemoveRange with chunks", function()
	local buffer = MarkupBuffer.New()
	buffer:AddString("hello ")
	buffer:AddColor(Color(1, 0, 0, 1))
	buffer:AddString("world")
	T(buffer:GetText())["=="]("hello world")
	-- Insert inside "hello "
	buffer:Insert(6, "!")
	T(buffer:GetText())["=="]("hello! world")
	-- Remove "world"
	buffer:RemoveRange(8, 13)
	T(buffer:GetText())["=="]("hello! ")
end)

T.Test("MarkupBuffer UTF-8 operations", function()
	local buffer = MarkupBuffer.New("héllo")
	T(buffer:GetLength())["=="](5)
	buffer:Insert(3, "X")
	T(buffer:GetText())["=="]("héXllo")
	buffer:RemoveRange(3, 4)
	T(buffer:GetText())["=="]("héllo")
end)

T.Test("MarkupBuffer InsertChunks", function()
	local buffer = MarkupBuffer.New("ac")
	buffer:InsertChunks(2, {{type = "string", val = "b"}})
	T(buffer:GetText())["=="]("abc")
	local buffer2 = MarkupBuffer.New("start end")
	buffer2:InsertChunks(
		7,
		{
			{type = "color", val = Color(1, 0, 0, 1)},
			{type = "string", val = "middle "},
			{type = "tag_stopper", val = true},
		}
	)
	T(buffer2:GetText())["=="]("start middle end")
	local full = buffer2:GetFullText()
	T(full:find("<color=1,0,0,1>middle </>"))["~="](nil)
end)

T.Test("MarkupBuffer GetFullText variations", function()
	local buffer = MarkupBuffer.New()
	buffer:AddColor(Color(1, 0, 0, 1))
	buffer:AddString("a")
	local full = buffer:GetFullText()
	T(full:find("<color=1,0,0,1>"))["~="](nil, "Tag at the beginning should be included")
	buffer = MarkupBuffer.New()
	buffer:AddString("a")
	buffer:AddColor(Color(1, 0, 0, 1))
	buffer:AddString("b")
	buffer:AddColor(Color(0, 1, 0, 1))
	buffer:AddString("c")
	T(buffer:GetFullTextSub(1, 2))["=="]("a")
	T(buffer:GetFullTextSub(2, 3))["=="]("<color=1,0,0,1>b")
	T(buffer:GetFullTextSub(3, 4))["=="]("<color=0,1,0,1>c")
	T(buffer:GetFullTextSub(1, 4))["=="]("a<color=1,0,0,1>b<color=0,1,0,1>c")
end)

T.Test2D("Markup basic usage", function()
	local m = Markup.New("test")
	T(m:GetText())["=="]("test")
	m:SetText("<color=1,0,0,1>red</color> blue", true)
	T(m:GetText())["=="]("red blue")
	-- Test backspace
	m:SetCaretSubPosition(3) -- after 're'
	m:Backspace()
	T(m:GetText())["=="]("rd blue")
end)

T.Test2D("Markup tags", function()
	local m = Markup.New()
	m:SetText("normal <font=default>custom font</font>", true)
	-- We can't easily verify the font was applied without layout, but we can verify it doesn't crash
	m:Invalidate()
	local text = m:GetText()
	T(text)["=="]("normal custom font")
end)

T.Test2D("Markup editor actions", function()
	local m = Markup.New("hello world")
	m:SetCaretSubPosition(6) -- at the space
	m:Enter()
	T(m:GetText())["=="]("hello\n world")
	m:Backspace() -- removes the newline
	T(m:GetText())["=="]("hello world")
	m:SetCaretSubPosition(6)
	m:Delete() -- removes the space
	T(m:GetText())["=="]("helloworld")
	m:Paste(" test")
	T(m:GetText())["=="]("hello testworld")
end)

T.Test2D("Markup selection and deletion", function()
	local m = Markup.New("hello world")
	m.editor.SelectionStart = 1
	m.editor.Cursor = 6 -- after 'hello'
	T(m:GetSelection())["=="]("hello")
	m:DeleteSelection()
	T(m:GetText())["=="](" world")
end)

T.Test2D("Markup complex formatting", function() end)

T.Test2D("Markup caret and movement", function()
	local m = Markup.New("hello world")
	m:SetCaretSubPosition(1)
	T(m:GetCaretSubPosition())["=="](1)
	m:SetCaretSubPosition(6) -- at space
	T(m:GetCaretSubPosition())["=="](6)
	-- Test character class position (used for Ctrl+Arrows)
	m:Invalidate()
	-- m:GetNextCharacterClassPosition(1) should return the next word break
	-- However, it depends on self.chars which is built during Invalidate
	-- We can just check if it runs without error for now
	local x, y = m:GetNextCharacterClassPosition(1)
	T(type(x))["=="]("number")
end)

T.Test2D("Markup caret from nearby pixels uses nearest line", function()
	local m = Markup.New("hello")
	local data = m.chars[2].data
	local caret = m:CaretFromPixels(data.x + math.max(data.w * 0.5, 1), data.top + 1)
	T(caret.i)["=="](2)
end)

T.Test2D("Markup mouse release updates selection stop", function()
	local m = Markup.New("hello")
	local start = m.chars[1].data
	local stop = m.chars[4].data
	local stop_caret = m:CaretFromPixels(stop.x + math.max(stop.w * 0.5, 1), stop.y + 1)
	m:SetMousePosition(Vec2(start.x + 1, start.y + 1))
	m:OnMouseInput("button_1", true)
	m:SetMousePosition(Vec2(stop.x + math.max(stop.w * 0.5, 1), stop.y + 1))
	m:OnMouseInput("button_1", false)
	T(m.editor.Cursor)["=="](stop_caret.i)
end)

T.Test2D("Markup wraps oversized tokens with pretext", function()
	local m = Markup.New(nil, true)
	m:AddFont(base_font.New())
	m:AddString("abcdefgh")
	m:SetMaxWidth(16)
	m:Invalidate()
	local parts = {}
	local lines = {}

	for _, chunk in ipairs(m.chunks) do
		if chunk.type == "string" and chunk.val ~= "" and not chunk.internal then
			parts[#parts + 1] = chunk.val
			lines[#lines + 1] = chunk.line
		end
	end

	T(table.concat(parts, ","))["=="]("ab,cd,ef,gh")
	T(table.concat(lines, ","))["=="]("1,2,3,4")
end)

T.Test2D("Markup preserves word wrapping with fixed metrics", function()
	local m = Markup.New(nil, true)
	m:AddFont(base_font.New())
	m:AddString("hello world again")
	m:SetMaxWidth(40)
	m:Invalidate()
	local words = {}
	local lines = {}

	for _, chunk in ipairs(m.chunks) do
		if chunk.type == "string" and chunk.val:find("^%S+$") and not chunk.internal then
			words[#words + 1] = chunk.val
			lines[#lines + 1] = chunk.line
		end
	end

	T(table.concat(words, ","))["=="]("hello,world,again")
	T(table.concat(lines, ","))["=="]("1,2,3")
end)

T.Test2D("Markup visual down movement follows wrapped layout", function()
	local m = Markup.New(nil, true)
	m:AddFont(base_font.New())
	m:AddString("abcdefgh")
	m:SetEditable(true)
	m:SetMaxWidth(16)
	m:Invalidate()
	m:SetCaretSubPosition(1)

	local caret = m.caret_pos
	local expected = m:CaretFromPixels(caret.char.data.x + caret.char.data.w / 2, caret.char.data.y + caret.char.data.h + 1)
	m:OnKeyInput("down")
	T(m.editor.Cursor)["=="](expected.i)
end)
