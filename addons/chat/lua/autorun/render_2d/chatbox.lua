local event = import("goluwa/event.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local Markup = import("goluwa/render2d/markup.lua")
local MarkupLabel = import("goluwa/render2d/ui/elements/markup_label.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local input = import("goluwa/input.lua")
local autocomplete = import("goluwa/autocomplete.lua")
local command_input = import("goluwa/cli/command_input.lua")
local chat = import("addons/chat/lua/autorun/chat.lua")
local InputHistory = import("goluwa/input_history.lua")
local chatbox = {}
chatbox.history = InputHistory.New{Name = "chat"}
chatbox.autocomplete = autocomplete.NewSession{RandomCount = 100, GetQuery = command_input.GetQuery}
chatbox.text_edit = NULL
chatbox.markup_chatbox = NULL
chatbox.markup_hud = NULL
chatbox.life_time = 30
chatbox.visible = false

do
	chatbox.markup_chatbox = Markup.New()
	chatbox.markup_chatbox:SetEditable(false)
	chatbox.markup_chatbox:SetSelectable(true)
	chatbox.markup_hud = Markup.New()
	chatbox.markup_hud:SetEditable(false)
	chatbox.markup_hud:SetSelectable(false)
	chatbox.font_modifiers = {}
	chatbox.emote_shortucts = chatbox.emote_shortucts or
		{
			bubu = "<remember=bubu><color=1,0.3,0.2><texture=materials/hud/killicons/default.vtf,50>  <translate=0,-15><color=0.58,0.239,0.58><font=ChatFont>Bubu<color=1,1,1>:</translate></remember>",
		}
	chatbox.tags = chatbox.tags or {}
end

function chatbox.IsVisible()
	return chatbox.visible
end

function chatbox.SetInputText(str)
	chatbox.text_edit:SetText(str or "")
end

function chatbox.GetInputText()
	return chatbox.text_edit:GetText()
end

function chatbox.AddText(...)
	local args = {}

	for _, v in pairs({...}) do
		local t = typex(v)

		if t == "client" then
			list.insert(args, v:GetUniqueColor())
			list.insert(args, v:GetNick())
			list.insert(args, Markup.ResetColor)
		elseif t == "string" then
			if v == ": sh" or v == "sh" or v:find("%ssh%s") then
				chatbox.markup_hud:TagPanic()
				chatbox.markup_chatbox:TagPanic()
			end

			v = v:gsub("<remember=(.-)>(.-)</remember>", function(key, val)
				chatbox.emote_shortucts[key] = val
			end)
			v = v:gsub("(:[%a%d]-:)", function(str)
				str = str:sub(2, -2)

				if chatbox.emote_shortucts[str] then
					return chatbox.emote_shortucts[str]
				end
			end)
			v = v:gsub("\\n", "\n")
			v = v:gsub("\\t", "\t")

			for pattern, font in pairs(chatbox.font_modifiers) do
				if v:find(pattern, nil, true) then list.insert(args, #args - 1, font) end
			end

			list.insert(args, v)
		else
			list.insert(args, v)
		end
	end

	event.Call("ChatAddText", args)
	chatbox.markup_hud:BeginLifeTime(chatbox.life_time)

	do
		chatbox.markup_hud:AddTable(args, true)
		chatbox.markup_hud:AddTagStopper()
		chatbox.markup_hud:AddString("\n")
	end

	do
		chatbox.markup_chatbox:AddTable(args, true)
		chatbox.markup_chatbox:AddTagStopper()
		chatbox.markup_chatbox:AddString("\n")
	end

	chatbox.markup_hud:EndLifeTime()

	for k, v in pairs(chatbox.tags) do
		chatbox.markup_chatbox.tags[k] = v
		chatbox.markup_hud.tags[k] = v
	end
end

local ChatWindow = react.Component(|| -> do
	local edit, set_edit = react.UseState()

	react.UseEffect(|| -> do
		if edit then edit:RequestTextFocus() end
	end, {edit})

	return {
		ui.Window{Name = "chatbox", Title = "chat", Padding = "XS"}{
			ui.MarkupPanel{
				Markup = chatbox.markup_chatbox,
				AdaptColors = true,
				layout = {MinSize = Vec2(0, 0), MaxSize = Vec2(10000, 10000), GrowHeight = 1},
			},
			ui.Row{layout = {AlignmentY = "start", ChildGap = "XS"}}{
				ui.TextEdit{
					Ref = |entity| -> do
						chatbox.text_edit = entity ?? NULL
						set_edit(entity)
					end,
					Text = "",
					Editable = true,
					History = chatbox.history,
					Autocomplete = chatbox.autocomplete,
					AutocompleteGhost = false,
					ScrollY = true,
					FontSize = "M",
					Wrap = true,
					AutoResize = true,
					layout = {GrowWidth = 1},
					Padding = Rect(4, 4, 4, 4),
					OnTextChanged = |_, text| -> event.Call("ChatTextChanged", text),
					OnKeyInput = |_, key, press| -> do
						if not press then return end

						if key == "escape" then
							chatbox.Hide()

							return true
						elseif key == "enter" and not input.IsShiftDown() then
							chatbox.text_edit:CommitHistory()
							event.Call("ChatBoxInput", chatbox.text_edit:GetText())
							chatbox.Hide()

							return true
						end
					end,
				},
				ui.MarkupTagPicker{Target = edit},
			},
		},
		edit && react.Portal{Target = Panel.World}{ui.AutocompleteList{Target = edit, Transparent = true}},
	}
end)
local ChatRoot = react.Component(|| -> do
	local open, set_open = react.UseState(false)

	react.UseEvent("ChatboxVisible", set_open)

	return open && ChatWindow{}
end)

function chatbox.Show()
	if event.Call("ChatOpen") == false then return end

	chatbox.autocomplete:Reseed()

	if not chatbox.root then chatbox.root = react.Mount(ChatRoot{}, Panel.World) end

	chatbox.visible = true
	event.Call("ChatboxVisible", true)
end

function chatbox.Hide()
	chatbox.history:Reset()
	chatbox.autocomplete:Clear()

	if chatbox.text_edit:IsValid() then chatbox.text_edit:RequestTextUnFocus() end

	chatbox.visible = false
	event.Call("ChatboxVisible", false)
end

event.AddListener("PreDraw2D", "chatbox_hud", function()
	local w, h = render2d.GetSize()
	render2d.PushMatrix(50, h / 2)
	MarkupLabel.SyncTheme(chatbox.markup_hud, "M", true)
	chatbox.markup_hud:Update()
	chatbox.markup_hud:Draw()
	chatbox.markup_hud:SetMaxWidth(render2d.GetSize() * 0.3)
	render2d.PopMatrix()
end)

input.Bind("y", "show_chat", function()
	chatbox.Show()
end)

event.AddListener("Chat", "chatbox", function(name, str, client)
	local tbl = chat.AddTimeStamp()

	if client:IsValid() then list.insert(tbl, client:GetUniqueColor()) end

	list.insert(tbl, name)
	list.insert(tbl, Markup.ResetColor)
	list.insert(tbl, ": ")
	list.insert(tbl, str)
	chatbox.AddText(unpack(tbl))
end)

if RELOAD then chatbox.Show() end

return chatbox
