local Rect = require("structs.rect")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Panel = require("ecs.panel")
local Button = require("ui.elements.button")
local Text = require("ui.elements.text")
local ContextMenu = require("ui.elements.context_menu")
local MenuItem = require("ui.elements.context_menu_item")
local theme = require("ui.theme")
return function(props)
	local options = props.Options or {}
	local on_select = props.OnSelect
	local label_ent

	local function open_menu(self)
		local world_panel = Panel.World
		local x, y = self.transform:GetWorldMatrix():GetTranslation()
		y = y + self.transform:GetHeight()
		local menu_items = {}

		for i, opt in ipairs(options) do
			local text = type(opt) == "table" and opt.Text or tostring(opt)
			local val = type(opt) == "table" and opt.Value or opt
			table.insert(
				menu_items,
				MenuItem(
					{
						Text = text,
						OnClick = function()
							-- Close the context menu
							local active = world_panel:GetKeyed("ActiveContextMenu")

							if active then active:Remove() end

							if on_select then on_select(val, text, i) end
						end,
					}
				)
			)
		end

		world_panel:Ensure(
			ContextMenu(
				{
					Key = "ActiveContextMenu",
					Position = Vec2(x, y),
					OnClose = function(ent)
						ent:Remove()
					end,
					Children = menu_items,
				}
			)
		)
	end

	local dropdown = Button(
		{
			Size = props.Size or Vec2(200, 40),
			layout = props.layout or {Direction = "x", FitHeight = true, AlignmentY = "center"},
			OnClick = open_menu,
			Padding = props.Padding or (Rect() + theme.Sizes2.M),
			Children = {
				Text(
					{
						Text = props.Text or "Select...",
						Ref = function(self)
							label_ent = self
						end,
						IgnoreMouseInput = true,
						layout = {GrowWidth = 1, FitHeight = true},
						Color = props.Disabled and
							theme.GetColor("text_disabled") or
							theme.GetColor("text_foreground"),
					}
				),
				Text(
					{
						Text = " ▼",
						IgnoreMouseInput = true,
						layout = {FitWidth = true, FitHeight = true},
						Color = props.Disabled and
							theme.GetColor("text_disabled") or
							theme.GetColor("text_foreground"),
					}
				),
			},
		}
	)

	if props.GetText then
		dropdown.gui_element:AddLocalListener("OnDraw", function()
			if label_ent and label_ent:IsValid() then
				local txt = props.GetText()

				if label_ent.text:GetText() ~= txt then label_ent.text:SetText(txt) end
			end
		end)
	end

	return dropdown
end
