local T = import("test/environment.lua")
local TextUndo = import("goluwa/text_undo.lua")
local system = import("goluwa/system.lua")

local function make(text)
	local undo = TextUndo.New{MergeTime = 1000}
	undo:Reset(text or "", 1)
	return undo
end

T.Test("text undo starts with nothing to undo or redo", function()
	local undo = make("abc")
	T(undo:CanUndo())["=="](false)
	T(undo:CanRedo())["=="](false)
	T(undo:Undo())["=="](nil)
	T(undo:Redo())["=="](nil)
end)

T.Test("text undo merges typed characters of one word", function()
	local undo = make("")
	undo:Push("h", 2)
	undo:Push("he", 3)
	undo:Push("hel", 4)
	T(undo:GetCount())["=="](1)
	local state = undo:Undo()
	T(state.text)["=="]("")
	T(state.cursor)["=="](1)
	T(undo:CanUndo())["=="](false)
	T(undo:Redo().text)["=="]("hel")
end)

T.Test("text undo starts a new group at a space", function()
	local undo = make("")

	for i, text in ipairs{"a", "ab", "ab ", "ab c", "ab cd"} do
		undo:Push(text, i + 1)
	end

	T(undo:GetCount())["=="](2)
	T(undo:Undo().text)["=="]("ab")
	T(undo:Undo().text)["=="]("")
end)

T.Test("text undo does not merge typing that is not contiguous", function()
	local undo = make("")
	undo:Push("a", 2)
	undo:Push("ab", 3)
	undo:Push("xab", 2)
	T(undo:GetCount())["=="](2)
	T(undo:Undo().text)["=="]("ab")
end)

T.Test("text undo merges backspace runs and restores the cursor", function()
	local undo = make("hello")
	undo:Push("hell", 5)
	undo:Push("hel", 4)
	T(undo:GetCount())["=="](1)
	local state = undo:Undo()
	T(state.text)["=="]("hello")
	T(state.cursor)["=="](6)
end)

T.Test("text undo keeps pastes and replacements as their own entries", function()
	local undo = make("ab")
	undo:Push("abcd", 5)
	undo:Push("abcdef", 7)
	T(undo:GetCount())["=="](2)
	undo:Push("x", 2)
	T(undo:GetCount())["=="](3)
	T(undo:Undo().text)["=="]("abcdef")
end)

T.Test("text undo drops the redo history after a new edit", function()
	local undo = make("")
	undo:Push("one", 4)
	undo:Push("one two", 8)
	undo:Undo()
	T(undo:CanRedo())["=="](true)
	undo:Push("onex", 5)
	T(undo:CanRedo())["=="](false)
	T(undo:Undo().text)["=="]("one")
end)

T.Test("text undo does not merge into an undone state", function()
	local undo = make("")
	undo:Push("a", 2)
	undo:Push("ab", 3)
	undo:Push("abc ", 5)
	undo:Undo()
	undo:Push("abcd", 5)
	T(undo:GetCount())["=="](2)
end)

T.Test("text undo limit drops the oldest states", function()
	local undo = TextUndo.New{Limit = 3}
	undo:Reset("", 1)

	for i = 1, 6 do
		undo:Push(string.rep("x", i * 5), 1)
	end

	T(undo:GetCount())["=="](2)
	undo:Undo()
	undo:Undo()
	T(undo:CanUndo())["=="](false)
end)

T.Test("text undo ignores pushes of identical text", function()
	local undo = make("abc")
	undo:Push("abc", 2)
	T(undo:GetCount())["=="](0)
end)

T.Test("text undo handles multibyte characters", function()
	local undo = make("")
	undo:Push("é", 2)
	undo:Push("éa", 3)
	T(undo:GetCount())["=="](1)
	T(undo:Undo().text)["=="]("")
end)
