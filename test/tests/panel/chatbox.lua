local T = import("test/environment.lua")
local event = import("goluwa/event.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local InputHistory = import("goluwa/input_history.lua")
local chatbox = import("addons/chat/lua/autorun/render_2d/chatbox.lua")

local function find_all(root, type_name)
	local found = {}

	for _, child in ipairs(root:GetChildrenList()) do
		if child.Type == type_name then found[#found + 1] = child end
	end

	return found
end

local function chat_window()
	for _, child in ipairs(Panel.World:GetChildren()) do
		if child.Type == "panel_window" and child:GetName() == "chatbox" then return child end
	end
end

T.Test2D("chatbox mounts when shown, floats its suggestion list and unmounts after enter or escape", function()
	chatbox.history = InputHistory.New()
	local submitted = {}
	event.AddListener("ChatBoxInput", "chatbox_test", function(text)
		submitted[#submitted + 1] = text
	end)
	T(chatbox.IsVisible())["=="](false)
	T(chat_window() == nil)["=="](true)
	chatbox.Show()
	react.Flush()
	T(chatbox.IsVisible())["=="](true)
	local window = chat_window()
	T(window ~= nil)["=="](true)
	local edit = chatbox.text_edit
	T(edit:IsValid())["=="](true)
	T(#find_all(Panel.World, "panel_autocomplete_list"))["=="](1)
	chatbox.SetInputText("hello chat")
	T(chatbox.GetInputText())["=="]("hello chat")
	T(edit.OnKeyInput(edit, "enter", true))["=="](true)
	react.Flush()
	T(submitted[1])["=="]("hello chat")
	T(chatbox.IsVisible())["=="](false)
	T(window:IsValid())["=="](false)
	T(#find_all(Panel.World, "panel_autocomplete_list"))["=="](0)
	T(chatbox.history:GetCount())["=="](1)
	chatbox.Show()
	react.Flush()
	local second = chat_window()
	T(second ~= nil and second ~= window)["=="](true)
	T(chatbox.text_edit:GetText())["=="]("")
	T(chatbox.text_edit.OnKeyInput(chatbox.text_edit, "escape", true))["=="](true)
	react.Flush()
	T(second:IsValid())["=="](false)
	T(#submitted)["=="](1)
	event.RemoveListener("ChatBoxInput", "chatbox_test")
end)
