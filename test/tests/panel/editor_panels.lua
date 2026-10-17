local T = import("test/environment.lua")
local react = import("goluwa/render2d/ui/react.lua")
local HistoryPanel = import("lua/history_panel.lua")
local NamePrompt = import("lua/name_prompt.lua")
local editor_history = import("lua/editor_history.lua")
local history = editor_history.history

local function find_all(root, type_name)
	local found = {}

	for _, child in ipairs(root:GetChildrenList()) do
		if child.Type == type_name then found[#found + 1] = child end
	end

	return found
end

local function button(root, text)
	for _, candidate in ipairs(find_all(root, "panel_button")) do
		if candidate:GetText() == text then return candidate end
	end
end

local function has_text(root, text)
	for _, candidate in ipairs(find_all(root, "panel_text")) do
		if candidate.text:GetText() == text then return true end
	end

	return false
end

T.Test2D("history panel follows the history and acts on it", function()
	history:Clear()
	local log = {}

	local function push(name)
		history:Push{
			Name = name,
			Undo = function()
				log[#log + 1] = "undo " .. name
			end,
			Redo = function()
				log[#log + 1] = "redo " .. name
			end,
		}
	end

	push("one")
	push("two")
	local window = HistoryPanel()
	T(HistoryPanel())["=="](window)
	T(button(window, "original state") ~= nil)["=="](true)
	T(button(window, "1  one") ~= nil)["=="](true)
	T(button(window, "2  two") ~= nil)["=="](true)
	T(button(window, "Undo"):GetDisabled())["=="](false)
	T(button(window, "Redo"):GetDisabled())["=="](true)
	button(window, "Undo"):CallLocalEvent("OnClick")
	react.Flush()
	T(history:GetIndex())["=="](1)
	T(log[1])["=="]("undo two")
	T(button(window, "Redo"):GetDisabled())["=="](false)
	button(window, "original state"):CallLocalEvent("OnClick")
	react.Flush()
	T(history:GetIndex())["=="](0)
	T(button(window, "Undo"):GetDisabled())["=="](true)
	local first = button(window, "1  one")
	local second = button(window, "2  two")
	push("three")
	react.Flush()
	T(button(window, "1  three"))["=="](first)
	T(button(window, "2  two") == nil)["=="](true)
	T(second:IsValid())["=="](false)
	button(window, "Clear"):CallLocalEvent("OnClick")
	react.Flush()
	T(#history:GetEntries())["=="](0)
	T(button(window, "Clear"):GetDisabled())["=="](true)
	window:Remove()
	react.Flush()
	push("after close")
	react.Flush()
	history:Clear()
end)

T.Test2D("name prompt validates, trims, submits and closes", function()
	local submitted
	local validate = function(name)
		if name == "bad" then return "no bad names" end
	end
	local window = NamePrompt{Title = "NAME", Text = "abc", Validate = validate, OnSubmit = function(name)
		submitted = name
	end}
	T(NamePrompt{Title = "other"})["=="](window)
	local edit = find_all(window, "panel_text_edit")[1]
	T(edit:GetText())["=="]("abc")
	edit:SetText("bad")
	button(window, "OK"):CallLocalEvent("OnClick")
	react.Flush()
	T(submitted)["=="](nil)
	T(has_text(window, "no bad names"))["=="](true)
	edit.OnTextChanged(edit, "x")
	react.Flush()
	T(has_text(window, "no bad names"))["=="](false)
	edit:SetText("")
	button(window, "OK"):CallLocalEvent("OnClick")
	T(submitted)["=="](nil)
	T(window:IsValid())["=="](true)
	edit:SetText("  spaced name  ")
	T(edit.OnKeyInput(edit, "enter", true))["=="](true)
	T(submitted)["=="]("spaced name")
	react.Flush()
	T(window:IsValid())["=="](false)
	submitted = nil
	local again = NamePrompt{Title = "NAME", OnSubmit = function(name)
		submitted = name
	end}
	T(again ~= window)["=="](true)
	button(again, "Cancel"):CallLocalEvent("OnClick")
	react.Flush()
	T(again:IsValid())["=="](false)
	T(submitted)["=="](nil)
end)
