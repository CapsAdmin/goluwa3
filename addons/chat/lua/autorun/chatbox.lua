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
local chat = import("addons/chat/lua/autorun/chat.lua")
local chatbox = {}
chatbox.panel = nil
chatbox.edit = nil
chatbox.scroll_panel = nil
chatbox.markup = nil
chatbox.life_time = 30
local panel_width = 400
local input_height = 50

do
	-- Initialize global markup template
	chatbox.markup = Markup.New()
	chatbox.markup:SetEditable(false)
	chatbox.markup:SetSelectable(false)
	-- Font and emote shortcuts (keep for reference)
	chatbox.font_modifiers = {}
	chatbox.emote_shortucts = chatbox.emote_shortucts or
		{
			bubu = "<remember=bubu><color=1,0.3,0.2><texture=materials/hud/killicons/default.vtf,50>  <translate=0,-15><color=0.58,0.239,0.58><font=ChatFont>Bubu<color=1,1,1>:</translate></remember>",
		}
	chatbox.tags = chatbox.tags or {}
end

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
				chatbox.markup:TagPanic()
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
	local markup = chatbox.markup
	markup:BeginLifeTime(chatbox.life_time)
	-- this will make everything added here get removed after said life time
	markup:AddFont(chatbox.font) -- also reset the font just in case
	markup:AddTable(args, true)
	markup:AddTagStopper()
	markup:AddString("\n")
	markup:EndLifeTime()

	--markup:SetMaxWidth(render2d.GetSize() * pos_mult:Get().x)
	for k, v in pairs(chatbox.tags) do
		markup.tags[k] = v
	end
end

function chatbox.Create()
	if chatbox.panel and chatbox.panel:IsValid() then return chatbox.panel end

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
					local w = chatbox.markup.width or 0
					local h = chatbox.markup.height or 0
					--render2d.SetColor(1, 0, 0, 1)
					--render2d.DrawRect(0, 0, w, h)
					local transform = self.transform
					chatbox.markup:Update()
					chatbox.markup:Draw()
					chatbox.markup:SetMaxWidth(render2d.GetSize() * 0.6)
					transform:SetSize(Vec2(w, h))
				end,
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
			Wrap = true,
			MinSize = Vec2(0, input_height),
			AutoResize = true,
			MaxLines = 4,
			OnTextChanged = function(self, text)
				chatbox.edit:ScrollCaretIntoView()
				event.Call("ChatTextChanged", text)
			end,
			OnKeyInput = function(self, key, press)
				if not press then return end

				chatbox.edit:ScrollCaretIntoView()

				if key == "escape" then
					chatbox.HideInput()
					return true
				elseif key == "enter" then
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

		local new_panel_height = size.y - input_height - 100
		local new_y = size.y - new_panel_height
		chatbox.panel.transform:SetPosition(Vec2(50, new_y))
		chatbox.panel.transform:SetSize(Vec2(panel_width, new_panel_height))
	end)

	-- Dynamically adjust panel height based on TextEdit's actual size
	local function UpdatePanelHeight()
		if not chatbox.edit or not chatbox.panel or not chatbox.panel:IsValid() then
			return
		end

		local text_panel = chatbox.edit:GetTextPanel()

		if not text_panel or not text_panel.transform or not text_panel.transform.size then
			return
		end

		local edit_height = text_panel.transform.size.y
		local min_edit_height = input_height
		local extra_height = math.max(0, edit_height - min_edit_height)
		-- Calculate total panel height needed
		local current_size = chatbox.panel.transform.size

		if not current_size then return end

		local new_panel_height = current_size.y + extra_height
		local window_size = system.GetWindow():GetSize()
		-- Ensure we don't exceed screen bounds
		local max_allowed_height = window_size.y - input_height - 100
		new_panel_height = math.min(new_panel_height, max_allowed_height)
		-- Update panel size and position to keep bottom aligned
		local new_y = window_size.y - new_panel_height
		chatbox.panel.transform:SetPosition(Vec2(50, new_y))
		chatbox.panel.transform:SetSize(Vec2(panel_width, new_panel_height))
	end

	-- Set up listener for text changes
	if chatbox.edit and chatbox.edit:GetTextPanel() then
		UpdatePanelHeight()

		event.AddListener("ChatTextChanged", "update_chatbox_height", function(text)
			UpdatePanelHeight()
		end)
	end

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
	chatbox.edit:SetText("")
	chatbox.edit:RequestTextUnFocus()
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
	if chatbox.panel and chatbox.panel:IsValid() then
		chatbox.panel:Remove()
		chatbox.panel = nil
	end

	chatbox.Show()
end

return chatbox
