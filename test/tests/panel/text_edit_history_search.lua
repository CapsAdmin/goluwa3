local T = import("test/environment.lua")
local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
local AutocompleteList = import("goluwa/render2d/ui/widgets/autocomplete_list.lua")
local InputHistory = import("goluwa/input_history.lua")
local autocomplete = import("goluwa/autocomplete.lua")
local event = import("goluwa/event.lua")

local function key(name, control)
	event.Call("KeyInput", "left_control", control and true or false)
	event.Call("KeyInput", name, true)
	event.Call("KeyInput", "left_control", false)
end

local function type_text(text_edit, text)
	text_edit:SetText(text)
	text_edit:GetTextPanel().text.editor.Cursor = #text + 1
	text_edit:sync_text_changed()
end

local function create(entries, props)
	local history = InputHistory.New()

	for _, entry in ipairs(entries) do
		history:Add(entry)
	end

	props = props or {}
	props.History = history
	local text_edit = TextEdit(props)
	text_edit:RequestTextFocus()
	return text_edit, history
end

local function result_values(text_edit)
	local out = {}

	for i, result in ipairs(text_edit.Autocomplete:GetResults()) do
		out[i] = result.val
	end

	return table.concat(out, ",")
end

T.Test2D("history search lists matches newest first and cancels with escape", function()
	local text_edit = create{"say hello", "help me", "hello world", "quit"}
	type_text(text_edit, "hel")
	key("r", true)
	T(text_edit._search ~= nil)["=="](true)
	T(result_values(text_edit))["=="]("hello world,help me,say hello")
	key("escape")
	T(text_edit._search)["=="](nil)
	T(text_edit:GetText())["=="]("hel")
	text_edit:Remove()
end)

T.Test2D("history search accepts the selected entry with enter without sending", function()
	local keys = {}
	local text_edit = create(
		{"alpha one", "beta", "alpha two"},
		{
			OnKeyInput = function(_, key_name)
				if key_name == "enter" then
					table.insert(keys, key_name)
					return true
				end
			end,
		}
	)
	type_text(text_edit, "alpha")
	key("r", true)
	key("r", true)
	key("enter")
	T(text_edit:GetText())["=="]("alpha one")
	T(#keys)["=="](0)
	T(text_edit._search)["=="](nil)
	text_edit:Remove()
end)

T.Test2D("history search shows everything newest first for an empty query", function()
	local text_edit = create{"one", "two", "three"}
	key("r", true)
	T(result_values(text_edit))["=="]("three,two,one")
	key("tab")
	T(text_edit:GetText())["=="]("three")
	text_edit:Remove()
end)

T.Test2D("history search follows typing and ends without a match", function()
	local text_edit = create{"foo bar", "baz"}
	key("r", true)

	for char in ("ba"):gmatch(".") do
		event.Call("CharInput", char)
	end

	T(result_values(text_edit))["=="]("baz,foo bar")

	for char in ("zzz"):gmatch(".") do
		event.Call("CharInput", char)
	end

	T(result_values(text_edit))["=="]("")
	key("enter")
	T(text_edit:GetText())["=="]("bazzz")
	T(text_edit._search)["=="](nil)
	text_edit:Remove()
end)

T.Test2D("history search needs history entries and restores the autocomplete session", function()
	local text_edit = create{}
	key("r", true)
	T(text_edit._search)["=="](nil)
	text_edit:Remove()
	autocomplete.AddList("test_search_restore", {"abc"})
	local session = autocomplete.NewSession{Lists = {"test_search_restore"}}
	local filled = create({"abc def"}, {Autocomplete = session})
	key("r", true)
	T(filled.Autocomplete ~= session)["=="](true)
	key("escape")
	T(filled.Autocomplete)["=="](session)
	T(autocomplete.HasList("history_search_" .. tostring(filled)))["=="](false)
	filled:Remove()
	autocomplete.RemoveList("test_search_restore")
end)

T.Test2D("history search ends when the text is set from code and shows in the suggestion list", function()
	local text_edit = create{"one", "two"}
	local list = AutocompleteList{Target = text_edit}
	text_edit.Autocomplete = nil
	key("r", true)
	list:OnUpdate()
	T(list.visual.Visible)["=="](true)
	T(#list._rows)["=="](3)
	text_edit:SetText("")
	T(text_edit._search)["=="](nil)
	list:Remove()
	text_edit:Remove()
end)
