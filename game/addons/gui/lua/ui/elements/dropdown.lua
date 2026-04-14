local Rect = import("goluwa/structs/rect.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Clickable = import("lua/ui/elements/clickable.lua")
local Text = import("lua/ui/elements/text.lua")
local event = import("goluwa/event.lua")
local timer = import("goluwa/timer.lua")
local ContextMenu = import("lua/ui/elements/context_menu.lua")
local MenuItem = import("lua/ui/elements/context_menu_item.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	local options = props.Options or {}
	local on_select = props.OnSelect
	local label_ent
	local dropdown
	local suppress_next_open = false
	local selected_text = props.Text or "Select..."

	for _, opt in ipairs(options) do
		local text = type(opt) == "table" and opt.Text or tostring(opt)
		local val = type(opt) == "table" and opt.Value or opt

		if props.Value ~= nil and val == props.Value then
			selected_text = text
			break
		end
	end

	local function open_menu(self)
		local world_panel = Panel.World

		if suppress_next_open then
			suppress_next_open = false
			return
		end

		local active = world_panel:GetKeyed("ActiveContextMenu")

		if active and active:IsValid() then
			if active.SourceDropdown == dropdown then
				active:Remove()
				return
			end

			active:Remove()
		end

		local x, y = self.transform:GetWorldMatrix():GetTranslation()
		local menu_items = {}

		-- Add options from props
		for i, opt in ipairs(options) do
			local text = type(opt) == "table" and opt.Text or tostring(opt)
			local val = type(opt) == "table" and opt.Value or opt
			table.insert(
				menu_items,
				MenuItem{
					Text = text,
					OnClick = function()
						suppress_next_open = true
						timer.Delay(0, function()
							suppress_next_open = false
						end)

						-- Close the context menu
						local active = world_panel:GetKeyed("ActiveContextMenu")

						if active and active:IsValid() then active:Remove() end

						selected_text = text

						if label_ent and label_ent:IsValid() and not props.GetText then
							label_ent.text:SetText(selected_text)
						end

						if on_select then on_select(val, text, i) end
					end,
				}
			)
		end

		-- Add options from children
		for _, child in ipairs(self:GetChildren()) do
			if not child.IsInternal then table.insert(menu_items, child) end
		end

		local context_menu = ContextMenu{
			Key = "ActiveContextMenu",
			SourceDropdown = dropdown,
			OnClose = function(ent)
				ent:Remove()
			end,
		}(menu_items)
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

	dropdown = Clickable{
		layout = {Direction = "x", FitHeight = true, AlignmentY = "center"},
		OnClick = open_menu,
		Padding = props.Padding or "M",
	}{
		Text{
			IsInternal = true,
			Text = selected_text,
			Ref = function(self)
				label_ent = self
			end,
			IgnoreMouseInput = true,
			layout = {GrowWidth = 1, FitHeight = true},
			Color = props.Disabled and "text_disabled" or "text_foreground",
		},
		Panel.New{
			IsInternal = true,
			Name = "DropdownIndicator",
			OnSetProperty = theme.OnSetProperty,
			transform = {
				Size = Vec2(16, 16),
			},
			gui_element = {
				OnDraw = function(self)
					theme.icons.dropdown_indicator(self.Owner, {
						size = 8,
						thickness = 2,
						color = theme.GetColor(props.Disabled and "text_disabled" or "text_foreground"),
					})
				end,
			},
			mouse_input = {
				IgnoreMouseInput = true,
			},
		},
	}

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
		dropdown:AddLocalListener("OnDraw", function()
			if label_ent and label_ent:IsValid() then
				local txt = props.GetText()

				if label_ent.text:GetText() ~= txt then label_ent.text:SetText(txt) end
			end
		end)
	end

	return dropdown
end
