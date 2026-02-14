local Rect = require("structs.rect")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Panel = require("ecs.panel")
local Clickable = require("ui.elements.clickable")
local Text = require("ui.elements.text")
local event = require("event")
local ContextMenu = require("ui.elements.context_menu")
local MenuItem = require("ui.elements.context_menu_item")
local theme = require("ui.theme")
return function(props)
	local options = props.Options or {}
	local on_select = props.OnSelect
	local label_ent
	local dropdown

	local function open_menu(self)
		local world_panel = Panel.World
		local x, y = self.transform:GetWorldMatrix():GetTranslation()
		local menu_items = {}

		-- Add options from props
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

		-- Add options from children
		for _, child in ipairs(self:GetChildren()) do
			if not child.IsInternal then table.insert(menu_items, child) end
		end

		local context_menu = ContextMenu(
			{
				Key = "ActiveContextMenu",
				OnClose = function(ent)
					ent:Remove()
				end,
			}
		)(menu_items)
		local real_ctx = context_menu:GetChildren()[1]

		event.AddListener("Update", dropdown, function()
			if not dropdown:IsValid() or not real_ctx:IsValid() then
				return event.destroy_tag
			end

			local w = dropdown.transform:GetSize().x
			real_ctx.layout:SetMinSize(Vec2(w, 0))
			local x, y = dropdown.transform:GetWorldMatrix():GetTranslation()
			y = y + dropdown.transform:GetHeight()
			real_ctx.transform:SetPosition(Vec2(x, y))
		end)

		world_panel:Ensure(context_menu)
	end

	dropdown = Clickable(
		{
			layout = {Direction = "x", FitHeight = true, AlignmentY = "center"},
			OnClick = open_menu,
			Padding = props.Padding or "M",
		}
	)(
		{
			Text(
				{
					IsInternal = true,
					Text = props.Text or "Select...",
					Ref = function(self)
						label_ent = self
					end,
					IgnoreMouseInput = true,
					layout = {GrowWidth = 1, FitHeight = true},
					Color = props.Disabled and "text_disabled" or "text_foreground",
				}
			),
			Text(
				{
					IsInternal = true,
					Text = " ▼",
					IgnoreMouseInput = true,
					layout = {FitWidth = true, FitHeight = true},
					Color = props.Disabled and "text_disabled" or "text_foreground",
				}
			),
		}
	)

	function dropdown:PreChildAdd(child)
		if child.IsInternal then return true end

		child.Visible = false
		child.ignore_layout = true
		return true -- we allow adding it as a child, but hidden
	end

	function dropdown:PreRemoveChildren()
		local children = self:GetChildren()

		for i = #children, 1, -1 do
			local child = children[i]

			if not child.IsInternal then
				child:UnParent()
				child:Remove()
			end
		end

		return false
	end

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
