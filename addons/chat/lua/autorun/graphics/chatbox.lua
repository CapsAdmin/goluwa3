local event = import("goluwa/event.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local resource = import("goluwa/resource.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
local Markup = import("goluwa/render2d/markup.lua") -- The markup rendering template
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local system = import("goluwa/system.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local input = import("goluwa/input.lua")
local pvars = import("goluwa/cli/pvars.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local chat = import("addons/chat/lua/autorun/chat.lua")
local chatbox = {}
chatbox.window = NULL
chatbox.text_edit = NULL
chatbox.markup_chatbox = NULL
chatbox.markup_hud = NULL
chatbox.life_time = 30
local panel_width = 400
local input_height = 50

do
	-- Initialize global markup template
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
	return chatbox.window.gui_element:IsVisible()
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
			list.insert(args, Color(1, 1, 1, 1))
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
		chatbox.markup_hud:AddFont(chatbox.font) -- also reset the font just in case
		chatbox.markup_hud:AddTable(args, true)
		chatbox.markup_hud:AddTagStopper()
		chatbox.markup_hud:AddString("\n")
	end

	do
		chatbox.markup_chatbox:AddFont(chatbox.font) -- also reset the font just in case
		chatbox.markup_chatbox:AddTable(args, true)
		chatbox.markup_chatbox:AddTagStopper()
		chatbox.markup_chatbox:AddString("\n")
	end

	chatbox.markup_hud:EndLifeTime()

	--markup:SetMaxWidth(render2d.GetSize() * pos_mult:Get().x)
	for k, v in pairs(chatbox.tags) do
		chatbox.markup_chatbox.tags[k] = v
		chatbox.markup_hud.tags[k] = v
	end
end

function chatbox.Show()
	if event.Call("ChatOpen") == false then return end

	if not chatbox.window:IsValid() then
		if false then
			resource.Download("data/steam_emotes.json"):Then(function(path)
				local i = 0

				for _, emote in ipairs(vfs.Read(path)) do
					local name = emote.name:sub(2, -2)
					chathud.emote_shortucts[name] = "<texture=http://cdn.steamcommunity.com/economy/emoticon/" .. name .. ">"
					i = i + 1
				end
			end)
		end

		local window_size = system.GetWindow():GetSize()
		local panel_x = 50
		local panel_height = window_size.y - input_height - 100
		local panel_y = window_size.y - panel_height
		chatbox.window = Window{
			Name = "chatbox",
			Title = "chat",
			Padding = "XS",
		}{
			ScrollablePanel{
				ScrollY = true,
				ScrollBarAutoHide = true,
				ScrollBarVisible = true,
				layout = {
					MinSize = Vec2(0, 0),
					MaxSize = Vec2(10000, 10000),
					GrowHeight = 1,
				},
			}{
				-- Container panel that draws the global markup object
				Panel.New{
					Name = "markup_container",
					transform = true,
					layout = {
						MinSize = Vec2(50, 50),
					},
					gui_element = true,
					OnDraw = function(self)
						local w = chatbox.markup_chatbox.width or 0
						local h = chatbox.markup_chatbox.height or 0
						local size = self:GetParent().transform:GetSize()
						render2d.SetColor(0, 0, 0, 1)
						render2d.DrawRect(0, 0, size.x, size.y)
						render2d.PushMatrix(4, 4)
						chatbox.markup_chatbox:Update()
						chatbox.markup_chatbox:Draw()
						chatbox.markup_chatbox:SetMaxWidth(render2d.GetSize() * 0.6)
						self.transform:SetSize(Vec2(w, h))
						render2d.PopMatrix()
					end,
				},
			},
			TextEdit{
				Ref = function(self)
					chatbox.text_edit = self
				end,
				Text = "",
				Editable = true,
				ScrollY = true,
				FontSize = "M",
				Wrap = true,
				MinSize = Vec2(0, input_height),
				AutoResize = true,
				OnTextChanged = function(self, text)
					chatbox.text_edit:ScrollCaretIntoView()
					event.Call("ChatTextChanged", text)
				end,
				OnKeyInput = function(self, key, press)
					if not press then return end

					chatbox.text_edit:ScrollCaretIntoView()

					if key == "escape" then
						chatbox.Hide()
						return true
					elseif key == "enter" then
						local text = chatbox.text_edit:GetText()

						if text and text ~= "" and not input.IsShiftDown() then
							event.Call("ChatBoxInput", tostring(text))
							chatbox.Hide()
							return true
						end
					end
				end,
			},
		}

		local function UpdatePanelHeight()
			if not chatbox.text_edit or not chatbox.window or not chatbox.window:IsValid() then
				return
			end

			local text_panel = chatbox.text_edit:GetTextPanel()

			if not text_panel or not text_panel.transform or not text_panel.transform.size then
				return
			end

			local edit_height = text_panel.transform.size.y
			local min_edit_height = input_height
			local extra_height = math.max(0, edit_height - min_edit_height)
			-- Calculate total panel height needed
			local current_size = chatbox.window.transform.size

			if not current_size then return end

			local new_panel_height = current_size.y + extra_height
			local window_size = system.GetWindow():GetSize()
			-- Ensure we don't exceed screen bounds
			local max_allowed_height = window_size.y - input_height - 100
			new_panel_height = math.min(new_panel_height, max_allowed_height)
			-- Update panel size and position to keep bottom aligned
			local new_y = window_size.y - new_panel_height
			chatbox.window.transform:SetPosition(Vec2(50, new_y))
			chatbox.window.transform:SetSize(Vec2(panel_width, new_panel_height))
		end

		-- Set up listener for text changes
		UpdatePanelHeight()

		event.AddListener("ChatTextChanged", "update_chatbox_height", function(text)
			UpdatePanelHeight()
		end)

		event.AddListener("Draw2D", "chatbox_hud", function()
			local w, h = render2d.GetSize()
			render2d.PushMatrix(50, h / 2)
			local w = chatbox.markup_hud.width or 0
			local h = chatbox.markup_hud.height or 0
			chatbox.markup_hud:Update()
			chatbox.markup_hud:Draw()
			chatbox.markup_hud:SetMaxWidth(render2d.GetSize() * 0.3)
			render2d.PopMatrix()
		end)
	end

	chatbox.window.gui_element:SetVisible(true)
	chatbox.text_edit:RequestTextFocus()
end

function chatbox.Hide()
	chatbox.window.gui_element:SetVisible(false)
	chatbox.text_edit:SetText("")
	chatbox.text_edit:RequestTextUnFocus()
end

-- Bind Y key to open/close chat input 
input.Bind("y", "show_chat", function()
	chatbox.Show()
end)

-- Listen for chat messages
event.AddListener("Chat", "chatbox", function(name, str, client)
	local tbl = chat.AddTimeStamp()

	if client:IsValid() then list.insert(tbl, client:GetUniqueColor()) end

	list.insert(tbl, name)
	list.insert(tbl, Color(1, 1, 1, 1))
	list.insert(tbl, ": ")
	list.insert(tbl, str)
	chatbox.AddText(unpack(tbl))
end)

if RELOAD then
	if chatbox.window and chatbox.window:IsValid() then
		chatbox.window:Remove()
		chatbox.window = nil
	end

	chatbox.Show()
end

return chatbox
