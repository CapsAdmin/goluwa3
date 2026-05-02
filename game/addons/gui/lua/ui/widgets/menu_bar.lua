local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/ecs/panel.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Frame = import("lua/ui/elements/frame.lua")
local Row = import("lua/ui/elements/row.lua")
local Text = import("lua/ui/elements/text.lua")
local ContextMenu = import("lua/ui/elements/context_menu.lua")
local theme = import("lua/ui/theme.lua")

local function resolve_menu_items(definition)
	local items = definition.Items or definition.Menu or definition.Submenu

	if type(items) == "function" then items = items() end

	return items or {}
end

local function get_passthrough_props(src)
	local out = {}

	if src.Key ~= nil then out.Key = src.Key end

	if src.Parent ~= nil then out.Parent = src.Parent end

	if src.Ref ~= nil then out.Ref = src.Ref end

	if src.Tooltip ~= nil then out.Tooltip = src.Tooltip end

	if src.TooltipOptions ~= nil then out.TooltipOptions = src.TooltipOptions end

	if src.TooltipMaxWidth ~= nil then out.TooltipMaxWidth = src.TooltipMaxWidth end

	if src.TooltipOffset ~= nil then out.TooltipOffset = src.TooltipOffset end

	if src.ChildOrder ~= nil then out.ChildOrder = src.ChildOrder end

	return out
end

local function create_menu_button(definition, on_click, on_hover)
	local button = NULL
	button = Panel.New{
		get_passthrough_props(definition),
		{
			Name = "MenuBarButton",
			transform = {
				Size = definition.Size or "M",
			},
			layout = {
				FitHeight = true,
				FitWidth = true,
				AlignmentX = "center",
				AlignmentY = "center",
				Padding = definition.Padding or "M",
			},
			gui_element = {
				Clipping = true,
				DrawAlpha = definition.Disabled and 0.5 or 1,
				OnDraw = function(self)
					theme.active:Draw(self.Owner)
				end,
			},
			mouse_input = {
				Cursor = definition.Disabled and "arrow" or "hand",
				OnMouseInput = function(self, button_name, press)
					if definition.Disabled then return end

					if button_name == "button_1" then
						self.Owner:SetState("pressed", press)
					end
				end,
				OnHover = function(self, hovered)
					self.Owner:SetState("hovered", hovered)
				end,
			},
			OnMouseEnter = function()
				if definition.Disabled then return end

				if on_hover then on_hover(button) end
			end,
			OnClick = not definition.Disabled and
				function()
					if on_click then return on_click(button) end
				end or
				nil,
			animation = true,
			clickable = true,
		},
	}(
		Text{
			Text = definition.Text,
			IgnoreMouseInput = true,
			Color = definition.Disabled and "text_disabled" or "text",
			AlignX = "center",
			AlignY = "center",
		}
	)
	button:SetState("hovered", false)
	button:SetState("pressed", false)
	button:SetState("disabled", not not definition.Disabled)
	button:SetState("active", false)

	function button:SetMenuBarActive(active)
		self:SetState("active", not not active)
		return self
	end

	return button
end

return function(props)
	props = props or {}
	local world_panel = Panel.World
	local menu_key = props.MenuKey or "ActiveMenuBarContextMenu"
	local bar = NULL
	local buttons = {}
	local active_index = nil
	local definitions = props.Items or {}

	local function sync_button_state()
		for index, button in ipairs(buttons) do
			if button and button:IsValid() then
				button:SetMenuBarActive(active_index == index)
			end
		end
	end

	local function close_active_menu()
		local active = world_panel:GetKeyed(menu_key)

		if active and active:IsValid() then active:Remove() end

		active_index = nil
		sync_button_state()
	end

	local function open_menu(index)
		local definition = definitions[index]

		if not definition or definition.Disabled then return end

		local items = resolve_menu_items(definition)
		local button = buttons[index]

		if #items == 0 then
			close_active_menu()

			if definition.OnClick then definition.OnClick(button, bar) end

			return
		end

		local active = world_panel:GetKeyed(menu_key)

		if active and active:IsValid() then active:Remove() end

		active_index = index
		sync_button_state()
		world_panel:Ensure(
			ContextMenu{
				Key = menu_key,
				Anchor = button,
				AnchorPlacement = definition.AnchorPlacement or "below_left",
				SourceMenuBar = bar,
				OnClose = function(ent)
					ent:Remove()
					active_index = nil
					sync_button_state()
				end,
			}(unpack(items))
		)
	end

	local row_children = {}

	for index, definition in ipairs(definitions) do
		row_children[#row_children + 1] = create_menu_button(definition, function()
			local active = world_panel:GetKeyed(menu_key)

			if active_index == index and active and active:IsValid() then
				close_active_menu()
				return true
			end

			open_menu(index)
			return true
		end, function()
			local active = world_panel:GetKeyed(menu_key)

			if active and active:IsValid() and active_index ~= index then
				open_menu(index)
			end
		end)
		buttons[index] = row_children[#row_children]
	end

	bar = Frame{
		Padding = props.Padding or "none",
		Emphasis = props.Emphasis or 0,
		layout = {
			GrowWidth = props.GrowWidth ~= false and 1 or 0,
			FitHeight = true,
			FitWidth = props.FitWidth ~= false,
			props.layout,
		},
	}{
		Row{
			layout = {
				GrowWidth = 1,
				FitHeight = true,
				ChildGap = props.ChildGap or "XXS",
				AlignmentY = "center",
			},
		}(row_children),
	}

	function bar:CloseMenu()
		close_active_menu()
		return self
	end

	event.AddListener("Update", bar, function()
		if not bar:IsValid() then return event.destroy_tag end

		local active = world_panel:GetKeyed(menu_key)

		if not active or not active:IsValid() then return end

		local mouse_pos = system.GetWindow():GetMousePosition()

		for index, button in ipairs(buttons) do
			if
				button and
				button:IsValid() and
				button.gui_element and
				button.gui_element:IsHovered(mouse_pos) and
				active_index ~= index and
				not definitions[index].Disabled
			then
				open_menu(index)

				break
			end
		end
	end)

	return bar
end
