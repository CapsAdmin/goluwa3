local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/ecs/panel.lua")
local SVG = import("lua/ui/elements/svg.lua")
local Text = import("lua/ui/elements/text.lua")
local theme = import("lua/ui/theme.lua")

local function find_context_menu_container(item)
	local current = item

	while current and current.IsValid and current:IsValid() do
		if current.IsContextMenuContainer then return current end

		current = current:GetParent()
	end
end

local function has_submenu(props)
	return props.Items ~= nil or props.Submenu ~= nil or props.Menu ~= nil
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

return function(props)
	props = props or {}
	local item = NULL
	local submenu = has_submenu(props)
	local children = {}

	local function close_context_menu()
		local container = find_context_menu_container(item)

		if container and container:IsValid() then container:Remove() end
	end

	local function close_deeper_submenus()
		local container = find_context_menu_container(item)
		local parent_menu = item:GetParent()

		if container and container:IsValid() and parent_menu and parent_menu:IsValid() then
			container:CloseFromLevel((parent_menu.ContextMenuLevel or 1) + 1)
		end
	end

	local function open_submenu()
		local container = find_context_menu_container(item)

		if not container or not container:IsValid() then return end

		container:OpenSubmenu(item, props)
	end

	if props.IconSource then
		children[#children + 1] = SVG{
			Source = props.IconSource,
			Size = Vec2(16, 16),
			MinSize = Vec2(16, 16),
			MaxSize = Vec2(16, 16),
			Color = props.Disabled and "text_disabled" or "text",
			IgnoreMouseInput = true,
			layout = {
				GrowWidth = 0,
				FitWidth = false,
			},
		}
	end

	children[#children + 1] = Text{
		layout = {
			GrowWidth = 1,
			MinSize = Vec2(10, 0),
			FitWidth = false,
			FitHeight = true,
		},
		Text = props.Text,
		DisableViewportCulling = props.DisableTextCulling == true,
		IgnoreMouseInput = true,
		Color = props.Disabled and "text_disabled" or "text",
	}

	if submenu then
		children[#children + 1] = Panel.New{
			IsInternal = true,
			transform = {
				Size = Vec2(16, 16),
			},
			layout = {
				GrowWidth = 0,
				FitWidth = false,
			},
			gui_element = {
				OnDraw = function(self)
					theme.active:DrawIcon(
						"disclosure",
						self.Owner.transform:GetSize(),
						{
							thickness = 2,
							color = theme.GetColor(props.Disabled and "text_disabled" or "text"),
						}
					)
				end,
			},
			mouse_input = {
				IgnoreMouseInput = true,
			},
		}
	end

	local item_props = get_passthrough_props(props)
	item_props.Name = "ContextMenuItem"
	item_props.transform = {
		Size = props.Size or "M",
	}
	item_props.layout = {
		Direction = "x",
		AlignmentY = "center",
		FitHeight = true,
		GrowWidth = 1,
		Padding = props.Padding or "M",
		props.layout,
	}
	item_props.gui_element = {
		Clipping = props.Clipping ~= false,
		DrawAlpha = props.Disabled and 0.5 or 1,
		OnDraw = function(self)
			theme.active:Draw(self.Owner)
		end,
	}
	item_props.mouse_input = {
		Cursor = props.Disabled and "arrow" or "hand",
		OnMouseInput = function(self, button, press)
			if props.Disabled then return end

			if button == "button_1" then self.Owner:SetState("pressed", press) end
		end,
		OnHover = function(self, hovered)
			self.Owner:SetState("hovered", hovered)
		end,
	}
	item_props.OnMouseEnter = function(self)
		if props.Disabled then
			close_deeper_submenus()
			return
		end

		if submenu then open_submenu() else close_deeper_submenus() end
	end
	item_props.OnClick = not props.Disabled and
		function(...)
			if submenu then
				open_submenu()
				return true
			end

			close_context_menu()

			if props.OnClick then return props.OnClick(...) end
		end or
		nil
	item_props.animation = true
	item_props.clickable = true
	item = Panel.New(item_props)(children)
	item:SetState("hovered", false)
	item:SetState("pressed", false)
	item:SetState("disabled", not not props.Disabled)
	item:SetState("active", not not props.Active)

	function item:SetSubmenuOpen(active)
		self:SetState("active", not not active)
		return self
	end

	return item
end
