local Panel = import("goluwa/render2d/ui/panel.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Clickable = import("goluwa/render2d/ui/elements/clickable.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")

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
	local button = Clickable{
		get_passthrough_props(definition),
		Disabled = definition.Disabled,
		Mode = "menu",
		OnMouseEnter = function()
			if definition.Disabled then return end

			if on_hover then on_hover(button) end
		end,
		OnClick = not definition.Disabled and
			function()
				if on_click then return on_click(button) end
			end or
			nil,
		Size = definition.Size or "M",
		layout = {
			FitHeight = true,
			FitWidth = true,
			AlignmentX = "center",
			AlignmentY = "center",
			Padding = definition.Padding or "M",
		},
	}(
		Text{
			Text = definition.Text,
			IgnoreMouseInput = true,
			InheritColor = true,
			AlignX = 0.5,
			AlignY = 0.5,
		}
	)

	function button:SetMenuBarActive(active)
		self:SetState("active", not not active)
		return self
	end

	return button
end

local META = Panel:CreateTemplate("menu_bar")
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "x",
	FitHeight = true,
	GrowWidth = 1,
}
META.CMP.visual = {}
META:GetSet("Items", {})
META:GetSet("MenuKey", "ActiveMenuBarContextMenu")
META:GetSet("ChildGap", "XXS")

function META:OnCreate(props)
	local create_props = {}

	for k, v in pairs(props) do
		create_props[k] = v
	end

	create_props.GrowWidth = nil
	create_props.FitWidth = nil
	local layout_cfg = {}

	for k, v in pairs(self.CMP.layout) do
		layout_cfg[k] = v
	end

	layout_cfg.GrowWidth = props.GrowWidth ~= false and 1 or 0
	layout_cfg.FitWidth = props.FitWidth ~= false
	create_props.layout = layout_cfg
	self.BaseClass.OnCreate(self, create_props)
	self.buttons = {}
	self.active_index = nil
	self.context_menu = NULL
	local items = props.Items or {}
	self:SetItems(items)
	local row_children = {}

	for index, definition in ipairs(items) do
		row_children[#row_children + 1] = create_menu_button(definition, function()
			if self.active_index == index then
				self:CloseMenu()
				return true
			end

			self:OpenMenu(index)
			return true
		end, function()
			if self.context_menu:IsValid() and self.active_index ~= index then
				self:OpenMenu(index)
			end
		end)
		self.buttons[index] = row_children[#row_children]
	end

	self.row = Row{
		IsInternal = true,
		Parent = self,
		layout = {
			GrowWidth = 1,
			FitHeight = true,
			ChildGap = self:GetChildGap(),
			AlignmentY = "center",
		},
	}(row_children)
	self:AddGlobalEvent("Update")
	self:AddGlobalEvent("KeyInput", {priority = math.huge})
end

function META:OnUpdate()
	if not self.context_menu:IsValid() then return end

	local mouse_pos = system.GetWindow():GetMousePosition()

	for index, button in ipairs(self.buttons) do
		if
			button and
			button:IsValid() and
			button.visual and
			button.visual:IsHovered(mouse_pos) and
			self.active_index ~= index and
			not self:GetItems()[index].Disabled
		then
			self:OpenMenu(index)

			break
		end
	end
end

function META:OnKeyInput(key, press)
	if not self.context_menu:IsValid() then return end

	if press and key == "escape" then
		self:CloseMenu()
		return false
	end
end

function META:_sync_button_state()
	for index, button in ipairs(self.buttons) do
		if button and button:IsValid() then
			button:SetMenuBarActive(self.active_index == index)
		end
	end
end

function META:CloseMenu()
	if self.context_menu:IsValid() then self.context_menu:Remove() end

	self.context_menu = NULL
	self.active_index = nil
	self:_sync_button_state()
	return self
end

function META:OpenMenu(index)
	local items = self:GetItems()
	local definition = items[index]

	if not definition or definition.Disabled then return end

	local menu_items = resolve_menu_items(definition)
	local button = self.buttons[index]

	if #menu_items == 0 then
		self:CloseMenu()

		if definition.OnClick then definition.OnClick(button, self) end

		return
	end

	self.active_index = index
	self.context_menu:Remove() -- remove immedeatly
	self.context_menu = Panel.OpenContextMenu(
		{
			Anchor = button,
			AnchorPlacement = definition.AnchorPlacement or "below_left",
			SourceMenuBar = self,
			OnClose = function(ent)
				ent:Remove()

				if not self:IsValid() then return end

				self.context_menu = NULL
				self.active_index = nil
				self:_sync_button_state()
			end,
		},
		unpack(menu_items)
	)
	self:_sync_button_state()
end

META:Register()
return META.New
