local event = import("goluwa/event.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local system = import("goluwa/system.lua")
local input = import("goluwa/input.lua")
local chat = import("addons/chat/lua/autorun/chat.lua")
local chatbox = {}
chatbox.panel = nil
chatbox.edit = nil
chatbox.scroll_panel = nil
chatbox.text_panel = nil
chatbox.messages = {}
chatbox.max_messages = 50
local panel_height = 250

function chatbox.IsVisible()
	return chatbox.panel and chatbox.panel:IsValid() and chatbox.panel.gui_element.Visible
end

function chatbox.SetInputText(str)
	if not chatbox.edit or not chatbox.edit:GetTextPanel() then return end

	chatbox.edit:SetText(str or "")
end

function chatbox.GetInputText()
	if not chatbox.edit or not chatbox.edit.GetText then return "" end

	return chatbox.edit:GetText()
end

local function add_message_line(name, color, message_text)
	if not chatbox.panel or not chatbox.panel:IsValid() then return end

	local scroll = chatbox.scroll_panel

	if not scroll or not scroll:IsValid() then return end

	local line = Panel.New{
		Name = "chat_line",
		transform = {
			Size = Vec2(0, 0),
		},
		layout = {
			FitWidth = true,
			FitHeight = true,
			MinSize = Vec2(0, 0),
		},
	}{
		Text{
			Text = name .. ": " .. message_text,
			Wrap = true,
			WrapToParent = true,
			FontName = "body",
			FontSize = "M",
			Color = color or "text",
			layout = {
				FitWidth = true,
				FitHeight = true,
				MinSize = Vec2(0, 0),
			},
		},
	}
	scroll:AddChild(line)
	chatbox.messages[#chatbox.messages + 1] = line

	-- Trim old messages
	while #chatbox.messages > chatbox.max_messages do
		local old = table.remove(chatbox.messages, 1)

		if old and old:IsValid() then old:Remove() end
	end

	-- Scroll to bottom
	if chatbox.scroll_panel and chatbox.scroll_panel.ScrollRectIntoView then
		chatbox.scroll_panel:ScrollRectIntoView(0, 0, 1e6, 1e6)
	end
end

function chatbox.AddText(...)
	local args = {...}
	local name = ""
	local color = nil
	local text = ""

	for _, v in ipairs(args) do
		local t = typex(v)

		if t == "color" then
			color = v
		elseif t == "string" then
			if name == "" then
				name = v
			else
				text = text .. (text ~= "" and " " or "") .. v
			end
		end
	end

	if name ~= "" or text ~= "" then add_message_line(name, color, text) end
end

function chatbox.Create()
	if chatbox.panel and chatbox.panel:IsValid() then return chatbox.panel end

	local window_size = system.GetWindow():GetSize()
	local panel_width = 400
	local panel_x = 50
	local panel_y = window_size.y - panel_height - 50
	chatbox.panel = Panel.New{
		Name = "chatbox",
		transform = {
			Size = Vec2(panel_width, panel_height),
			Position = Vec2(panel_x, panel_y),
		},
		layout = {
			Direction = "y",
			GrowHeight = 1,
			Padding = Rect() + 8,
			ChildGap = 6,
		},
		gui_element = {
			Visible = true,
		},
		style = {
			BackgroundColor = "surface",
		},
	}{
		ScrollablePanel{
			Ref = function(self)
				chatbox.scroll_panel = self
			end,
			ScrollY = true,
			ScrollBarAutoHide = true,
			ScrollBarVisible = true,
			Padding = Rect() + 2,
			layout = {
				GrowWidth = 1,
				GrowHeight = 1,
				Direction = "y",
				AlignmentY = "start",
				MinSize = Vec2(0, 0),
			},
		}{
			Text{
				Ref = function(self)
					chatbox.text_panel = self
				end,
				Text = "",
				Wrap = false,
				FontName = "body",
				FontSize = "M",
				Color = "text",
				layout = {
					FitWidth = true,
					FitHeight = true,
					MinSize = Vec2(0, 0),
				},
			},
		},
		TextEdit{
			Ref = function(self)
				chatbox.edit = self
			end,
			Text = "",
			Editable = true,
			ScrollY = true,
			FontSize = "M",
			MaxLines = 4,
			Wrap = true,
			MinSize = Vec2(0, 30),
			OnTextChanged = function(self, text)
				event.Call("ChatTextChanged", text)
				local lines, line_height, vertical_step, visible_start, visible_stop = chatbox.edit:GetTextPanel().text:GetTextSize2()

				if not lines then return end

				local line_count = math.min(#lines, 4)
				local w = self.layout:GetMinSize().x
				local h = line_count * vertical_step + vertical_step
				self.layout:SetMinSize(Vec2(w, h))
				self.layout:SetMaxSize(Vec2(w, h))
				chatbox.edit:ScrollCaretIntoView()
			end,
			OnKeyInput = function(self, key, press)
				chatbox.edit:ScrollCaretIntoView()

				if key == "escape" and press then
					chatbox.HideInput()
					return true
				end

				if key == "enter" and press then
					local text = chatbox.edit:GetText()

					if text and text ~= "" and not input.IsShiftDown() then
						event.Call("ChatBoxInput", tostring(text))
						chatbox.HideInput()
						return true
					end
				end
			end,
		},
	}
	chatbox.panel:AddGlobalEvent("WindowFramebufferResized")

	event.AddListener("WindowFramebufferResized", "chatbox_resize", function(window, size)
		if not chatbox.panel or not chatbox.panel:IsValid() then return end

		chatbox.panel.transform:SetPosition(Vec2(50, size.y - panel_height - 50))
	end)

	return chatbox.panel
end

function chatbox.Show()
	if event.Call("ChatOpen") == false then return end

	chatbox.Create()

	if not chatbox.panel or not chatbox.panel:IsValid() then return end

	chatbox.panel.gui_element.Visible = true
	chatbox.edit.gui_element.Visible = true

	if chatbox.edit then chatbox.edit:RequestTextFocus() end
end

function chatbox.HideInput()
	if not chatbox.edit or not chatbox.edit.gui_element then return end

	chatbox.edit.gui_element.Visible = false

	if chatbox.edit.GetText then chatbox.edit:SetText("") end

	-- Remove focus from edit so keyboard input stops being captured
	if chatbox.edit then chatbox.edit:RequestTextUnFocus() end
end

function chatbox.Close()
	if not chatbox.panel or not chatbox.panel:IsValid() then return end

	chatbox.panel.gui_element.Visible = false

	if chatbox.edit and chatbox.edit.GetText then chatbox.edit:SetText("") end
end

-- Bind Y key to open/close chat input 
input.Bind("y", "show_chat", function()
	chatbox.Show()
end)

-- Listen for chat messages
event.AddListener("Chat", "chatbox", function(name, str, client)
	local tbl = chat.AddTimeStamp()

	if client and client:IsValid() then
		tbl[#tbl + 1] = client:GetUniqueColor()
	end

	tbl[#tbl + 1] = name
	tbl[#tbl + 1] = Color(1, 1, 1, 1)
	tbl[#tbl + 1] = ": "
	tbl[#tbl + 1] = str
	chatbox.AddText(unpack(tbl))
end)

if RELOAD then
	if chatbox.panel and chatbox.panel:IsValid() then
		chatbox.panel:Remove()
		chatbox.panel = nil
	end

	chatbox.Show()
end

return chatbox
