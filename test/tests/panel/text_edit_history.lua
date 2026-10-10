local T = import("test/environment.lua")
local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
local InputHistory = import("goluwa/input_history.lua")
local event = import("goluwa/event.lua")

local function key(name)
	event.Call("KeyInput", name, true)
end

local function create(entries, props)
	local history = InputHistory.New()

	for _, entry in ipairs(entries) do
		history:Add(entry)
	end

	props = props or {}
	props.History = history
	props.Text = ""
	local text_edit = TextEdit(props)
	text_edit:RequestTextFocus()
	return text_edit, history
end

T.Test2D("text edit history up and down walk entries and restore the draft", function()
	local text_edit = create{"one", "two"}
	text_edit:SetText("draft")
	key("up")
	T(text_edit:GetText())["=="]("two")
	key("up")
	T(text_edit:GetText())["=="]("one")
	key("up")
	T(text_edit:GetText())["=="]("one")
	key("down")
	T(text_edit:GetText())["=="]("two")
	key("down")
	T(text_edit:GetText())["=="]("draft")
	text_edit:Remove()
end)

T.Test2D("text edit history puts the cursor at the end of the recalled entry", function()
	local text_edit = create{"hello world"}
	key("up")
	local editor = text_edit:GetTextPanel().text.editor
	T(editor.Cursor)["=="](#"hello world" + 1)
	text_edit:Remove()
end)

T.Test2D("text edit history only navigates from the first and last line of multiline text", function()
	local text_edit = create({"old"}, {Wrap = true, ScrollY = true})
	text_edit:SetText("a\nb\nc")
	local editor = text_edit:GetTextPanel().text.editor
	editor.Cursor = 4
	key("up")
	T(text_edit:GetText())["=="]("a\nb\nc")
	key("up")
	T(text_edit:GetText())["=="]("old")
	text_edit:Remove()
end)

T.Test2D("text edit history reports navigation", function()
	local calls = {}
	local text_edit = create(
		{"one", "two"},
		{
			OnHistoryNavigate = function(_, index, count)
				table.insert(calls, tostring(index) .. "/" .. count)
			end,
		}
	)
	key("up")
	key("up")
	key("down")
	key("down")
	T(table.concat(calls, " "))["=="]("2/2 1/2 2/2 nil/2")
	text_edit:Remove()
end)

T.Test2D("text edit commit history adds the text", function()
	local text_edit, history = create{}
	text_edit:SetText("sent")
	text_edit:CommitHistory()
	T(history:GetEntries()[1])["=="]("sent")
	text_edit:Remove()
end)
