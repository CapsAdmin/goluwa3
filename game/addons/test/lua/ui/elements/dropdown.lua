local Rect = require("structs.rect")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Panel = require("ecs.panel")
local Button = runfile("lua/ui/elements/button.lua")
local Text = runfile("lua/ui/elements/text.lua")
local ContextMenu = runfile("lua/ui/elements/context_menu.lua")
local MenuItem = runfile("lua/ui/elements/context_menu_item.lua")
local theme = runfile("lua/ui/theme.lua")
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
			Layout = props.Layout or {"SizeToChildrenHeight"},
			OnClick = open_menu,
			Padding = props.Padding or (Rect() + theme.Sizes2.M),
			Margin = props.Margin or Rect(),
			Children = {
				Text(
					{
						Text = props.Text or "Select...",
						Ref = function(self)
							label_ent = self
						end,
						IgnoreMouseInput = true,
						Layout = {"CenterSimple", "MoveLeft"},
						Color = props.Disabled and theme.Colors.TextDisabled or theme.Colors.TextNormal,
					}
				),
				Text(
					{
						Text = " ▼",
						IgnoreMouseInput = true,
						Layout = {"CenterSimple", "MoveRight"},
						Color = props.Disabled and theme.Colors.TextDisabled or theme.Colors.TextNormal,
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
