local T = import("test/environment.lua")
local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
local AutocompleteList = import("goluwa/render2d/ui/widgets/autocomplete_list.lua")
local autocomplete = import("goluwa/autocomplete.lua")
local event = import("goluwa/event.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local LIST_ID = "test_text_edit_autocomplete"

local function key(name)
	event.Call("KeyInput", name, true)
end

local function create(props)
	autocomplete.AddList(LIST_ID, {"help", "hello", "helmet", "say hello"})
	props = props or {}
	props.Autocomplete = autocomplete.NewSession{Lists = {LIST_ID}, RandomCount = 3}
	local text_edit = TextEdit(props)
	text_edit:RequestTextFocus()
	return text_edit, props.Autocomplete
end

local function type_text(text_edit, text)
	text_edit:SetText(text)
	text_edit:GetTextPanel().text.editor.Cursor = #text + 1
	text_edit:sync_text_changed()
end

local function ghost(text_edit)
	return text_edit:GetTextPanel().text.GhostText
end

local function cleanup(text_edit)
	text_edit:Remove()
	autocomplete.RemoveList(LIST_ID)
end

T.Test2D("text edit autocomplete shows the completion as ghost text", function()
	local text_edit = create()
	type_text(text_edit, "hel")
	T(ghost(text_edit))["=="]("p")
	T(text_edit:GetText())["=="]("hel")
	type_text(text_edit, "say")
	T(ghost(text_edit))["=="](" hello")
	type_text(text_edit, "zzz")
	T(ghost(text_edit))["=="]("")
	cleanup(text_edit)
end)

T.Test2D("text edit autocomplete can disable the ghost text", function()
	local text_edit, session = create{AutocompleteGhost = false}
	type_text(text_edit, "hel")
	T(ghost(text_edit))["=="]("")
	T(session:HasResults())["=="](true)
	key("tab")
	T(text_edit:GetText())["=="]("help")
	cleanup(text_edit)
end)

T.Test2D("text edit autocomplete has no ghost after tab put the completion in the input", function()
	local text_edit = create()
	type_text(text_edit, "hel")
	key("tab")
	T(text_edit:GetText())["=="]("help")
	T(ghost(text_edit))["=="]("")
	cleanup(text_edit)
end)

T.Test2D("text edit autocomplete hides the ghost when the cursor is not at the end", function()
	local text_edit = create()
	type_text(text_edit, "hel")
	text_edit:GetTextPanel().text.editor.Cursor = 2
	text_edit:sync_text_changed()
	T(ghost(text_edit))["=="]("")
	cleanup(text_edit)
end)

T.Test2D("text edit autocomplete tab accepts and cycles", function()
	local text_edit = create()
	type_text(text_edit, "hel")
	key("tab")
	T(text_edit:GetText())["=="]("help")
	key("tab")
	T(text_edit:GetText())["=="]("hello")
	key("tab")
	T(text_edit:GetText())["=="]("helmet")
	cleanup(text_edit)
end)

T.Test2D("text edit autocomplete tab without results falls through", function()
	local keys = {}
	local text_edit = create{
		OnKeyInput = function(_, key_name)
			table.insert(keys, key_name)
		end,
	}
	type_text(text_edit, "zzz")
	key("tab")
	T(table.concat(keys, ","))["=="]("tab")
	cleanup(text_edit)
end)

T.Test2D("text edit autocomplete arrows pick an entry and enter accepts only a picked entry", function()
	local keys = {}
	local text_edit, session = create{
		OnKeyInput = function(_, key_name)
			table.insert(keys, key_name)
			return true
		end,
	}
	type_text(text_edit, "hel")
	key("enter")
	T(table.concat(keys, ","))["=="]("enter")
	T(text_edit:GetText())["=="]("hel")
	key("down")
	T(session:GetSelectedIndex())["=="](2)
	T(ghost(text_edit))["=="]("lo")
	key("enter")
	T(text_edit:GetText())["=="]("hello")
	T(table.concat(keys, ","))["=="]("enter")
	T(session:HasResults())["=="](false)
	cleanup(text_edit)
end)

T.Test2D("text edit autocomplete escape closes the list before reaching the handler", function()
	local keys = {}
	local text_edit, session = create{
		OnKeyInput = function(_, key_name)
			table.insert(keys, key_name)
		end,
	}
	type_text(text_edit, "hel")
	key("escape")
	T(session:HasResults())["=="](false)
	T(ghost(text_edit))["=="]("")
	T(#keys)["=="](0)
	key("escape")
	T(table.concat(keys, ","))["=="]("escape")
	cleanup(text_edit)
end)

T.Test2D("text edit autocomplete right arrow accepts the ghost text", function()
	local text_edit = create()
	type_text(text_edit, "hel")
	key("right")
	T(text_edit:GetText())["=="]("help")
	T(ghost(text_edit))["=="]("")
	cleanup(text_edit)
end)

T.Test2D("text edit autocomplete up and down fall back to history without results", function()
	local InputHistory = import("goluwa/input_history.lua")
	local history = InputHistory.New()
	history:Add("earlier")
	local text_edit = create{History = history}
	key("up")
	T(text_edit:GetText())["=="]("earlier")
	cleanup(text_edit)
end)

T.Test2D("autocomplete list follows the results and accepts a clicked entry", function()
	local text_edit, session = create()
	local list = AutocompleteList{Target = text_edit}
	list:OnUpdate()
	T(list.visual.Visible)["=="](false)
	type_text(text_edit, "hel")
	list:OnUpdate()
	T(list.visual.Visible)["=="](true)
	T(#list._rows)["=="](4)
	T(list.transform:GetWidth())["=="](text_edit.transform:GetWidth())
	T(list.transform:GetHeight())[">"](0)
	session:Select(3)
	T(list:get_row_at(10))["=="](1)
	session:Select(1)
	text_edit.Autocomplete:Select(3)
	text_edit:AcceptAutocomplete()
	T(text_edit:GetText())["=="]("helmet")
	list:OnUpdate()
	T(list.visual.Visible)["=="](false)
	list:Remove()
	cleanup(text_edit)
end)

T.Test2D("autocomplete list removes itself with its target", function()
	local text_edit = create()
	local list = AutocompleteList{Target = text_edit}
	cleanup(text_edit)
	list:OnUpdate()
	T(list:IsValid())["=="](false)
end)

T.Test2D("text edit autocomplete tab on empty text picks from the random list", function()
	local text_edit, session = create()
	key("tab")
	local first = text_edit:GetText()
	T(first)["~="]("")
	T(first)["=="](session.random_results[1].val)
	key("tab")
	T(text_edit:GetText())["=="](session.random_results[2].val)
	text_edit:SetText("")
	key("tab")
	T(text_edit:GetText())["=="](session.random_results[3].val)
	cleanup(text_edit)
end)

T.Test2D("autocomplete list shows list headers for searches but not for the random pool", function()
	local other_id = LIST_ID .. "_other"
	local text_edit, session = create()
	autocomplete.AddList(other_id, {"helpful", "hellish"})
	autocomplete.SetListName(LIST_ID, "first list")
	autocomplete.SetListName(other_id, "second list")
	session.Lists = {LIST_ID, other_id}
	local list = AutocompleteList{Target = text_edit, MaxRows = 20}

	local function header_count()
		local count = 0

		for _, row in ipairs(list._rows) do
			if row.header then count = count + 1 end
		end

		return count
	end

	type_text(text_edit, "hel")
	list:OnUpdate()
	T(header_count())["=="](2)
	text_edit:SetText("")
	key("tab")
	list:OnUpdate()
	T(#list._rows)["=="](3)
	T(header_count())["=="](0)
	list:Remove()
	autocomplete.RemoveList(other_id)
	autocomplete.SetListName(LIST_ID, nil)
	autocomplete.SetListName(other_id, nil)
	cleanup(text_edit)
end)

T.Test2D("autocomplete list stays hidden while its target has no session", function()
	local text_edit = TextEdit{Text = ""}
	local list = AutocompleteList{Target = text_edit}
	list:OnUpdate()
	T(list.visual.Visible)["=="](false)
	list:Remove()
	text_edit:Remove()
end)

T.Test2D("text edit autocomplete lets arrows reach the history while only a hint is shown", function()
	local InputHistory = import("goluwa/input_history.lua")
	local history = InputHistory.New()
	history:Add("earlier")
	local session = autocomplete.NewSession{
		GetQuery = function(text)
			return text,
			"",
			{
				{
					id = "hint",
					source = {{val = "", detail = "usage", hint = true}},
					options = {NoFilter = true},
				},
			},
			true
		end,
	}
	local text_edit = TextEdit{History = history, Autocomplete = session, Text = ""}
	text_edit:RequestTextFocus()
	type_text(text_edit, "cmd ")
	T(session:HasResults())["=="](true)
	key("up")
	T(text_edit:GetText())["=="]("earlier")
	text_edit:Remove()
end)
