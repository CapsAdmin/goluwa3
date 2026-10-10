local T = import("test/environment.lua")
local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local event = import("goluwa/event.lua")

local function key(name, control, shift)
	event.Call("KeyInput", "left_control", control and true or false)
	event.Call("KeyInput", "left_shift", shift and true or false)
	event.Call("KeyInput", name, true)
	event.Call("KeyInput", "left_shift", false)
	event.Call("KeyInput", "left_control", false)
end

local function type_text(text)
	for char in text:gmatch(".") do
		event.Call("CharInput", char)
	end
end

local function create(props)
	local text_edit = TextEdit(props or {})
	text_edit:RequestTextFocus()
	return text_edit, text_edit:GetTextPanel().text.editor
end

T.Test2D("text edit undo and redo with the keyboard", function()
	local text_edit, editor = create()
	type_text("hello world")
	key("z", true)
	T(text_edit:GetText())["=="]("hello")
	T(editor.Cursor)["=="](6)
	key("z", true)
	T(text_edit:GetText())["=="]("")
	key("y", true)
	T(text_edit:GetText())["=="]("hello")
	key("z", true, true)
	T(text_edit:GetText())["=="]("hello world")
	text_edit:Remove()
end)

T.Test2D("text edit undo reports text changes", function()
	local changes = {}
	local text_edit = create{
		OnTextChanged = function(_, text)
			table.insert(changes, text)
		end,
	}
	type_text("ab")
	text_edit:Undo()
	T(changes[#changes])["=="]("")
	text_edit:Redo()
	T(changes[#changes])["=="]("ab")
	text_edit:Remove()
end)

T.Test2D("text edit set text resets the undo history", function()
	local text_edit, editor = create()
	type_text("typed")
	text_edit:SetText("replaced")
	T(editor:CanUndo())["=="](false)
	text_edit:Undo()
	T(text_edit:GetText())["=="]("replaced")
	text_edit:Remove()
end)

T.Test2D("text edit cut copy paste and select all", function()
	local text_edit, editor = create()
	text_edit:SetText("hello world")
	editor.Cursor = 12
	text_edit:SelectAll()
	T(editor.SelectionStart)["=="](1)
	text_edit:Cut()
	T(text_edit:GetText())["=="]("")
	text_edit:Paste()
	T(text_edit:GetText())["=="]("hello world")
	text_edit:Undo()
	T(text_edit:GetText())["=="]("")
	text_edit:Undo()
	T(text_edit:GetText())["=="]("hello world")
	text_edit:Remove()
end)

T.Test2D("text edit read only blocks editing actions but allows copy", function()
	local text_edit, editor = create{Editable = false, Text = "fixed"}
	text_edit:SelectAll()
	text_edit:Cut()
	text_edit:Paste()
	text_edit:Undo()
	T(text_edit:GetText())["=="]("fixed")
	text_edit:Copy()
	text_edit:Remove()
end)

T.Test2D("text edit context menu lists the editing actions and enables them by state", function()
	local text_edit, editor = create()
	text_edit:open_context_menu()
	local items = {}

	local function collect(panel)
		if panel.Action then items[panel.Action] = panel end

		for _, child in ipairs(panel:GetChildren()) do
			collect(child)
		end
	end

	collect(Panel.World)
	T(items.Undo.Disabled)["=="](true)
	T(items.Redo.Disabled)["=="](true)
	T(items.Cut.Disabled)["=="](true)
	T(items.Copy.Disabled)["=="](true)
	T(items.SelectAll.Disabled)["=="](true)
	Panel.CloseContextMenu()
	text_edit:RequestTextFocus()
	type_text("hello")
	editor.SelectionStart = 1
	editor.Cursor = 4
	text_edit:open_context_menu()
	items = {}
	collect(Panel.World)
	T(items.Undo.Disabled)["=="](false)
	T(items.Cut.Disabled)["=="](false)
	T(items.Copy.Disabled)["=="](false)
	T(items.SelectAll.Disabled)["=="](false)
	items.Cut:CallLocalEvent("OnClick")
	T(text_edit:GetText())["=="]("lo")
	Panel.CloseContextMenu()
	text_edit:Remove()
end)

T.Test2D("text edit context menu can be disabled", function()
	local text_edit = create{ContextMenu = false}
	local before = #Panel.World:GetChildren()
	text_edit.mouse_input.Owner:CallLocalEvent("OnMouseInput", "button_2", true)
	T(#Panel.World:GetChildren())["=="](before)
	text_edit:Remove()
end)
