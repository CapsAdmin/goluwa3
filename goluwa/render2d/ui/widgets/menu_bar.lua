local Panel = import("goluwa/render2d/ui/panel.lua")
local system = import("goluwa/system.lua")
local Rect = import("goluwa/structs/rect.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local META = Panel:CreateTemplate("menu_bar")
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "x",
	FitHeight = true,
	GrowWidth = 1,
	ChildGap = "XXS",
	AlignmentY = "center",
}
META.CMP.visual = {}
META:StartStorable()
META:GetSet("Items", nil)
META:GetSet("MenuKey", "ActiveMenuBarContextMenu")
META:EndStorable()

local function on_button_click(button)
	local menu_bar = button.MenuBar

	if menu_bar._active_index == button.MenuIndex then
		menu_bar:CloseMenu()
	else
		menu_bar:OpenMenu(button.MenuIndex)
	end

	return true
end

local function on_button_enter(button)
	local menu_bar = button.MenuBar

	if
		not button.Disabled and
		menu_bar._context_menu:IsValid() and
		menu_bar._active_index ~= button.MenuIndex
	then
		menu_bar:OpenMenu(button.MenuIndex)
	end
end

local function on_menu_close(context_menu)
	local menu_bar = context_menu.SourceMenuBar
	context_menu:Remove()

	if not menu_bar:IsValid() then return end

	menu_bar._context_menu = NULL
	menu_bar._active_index = nil
	menu_bar:sync_button_state()
end

function META:OnCreate(props)
	props.Items = props.Items or {}
	META.BaseClass.OnCreate(self, props)
	self._buttons = {}
	self._active_index = nil
	self._context_menu = NULL
	local horizontal = theme.active:GetPadding("M")
	local vertical = theme.active:GetPadding("S")
	self._button_padding = Rect(horizontal, vertical, horizontal, vertical)

	for index, definition in ipairs(self.Items) do
		self._buttons[index] = Button{
			Parent = self,
			IsInternal = true,
			MenuBar = self,
			MenuIndex = index,
			Key = definition.Key,
			Ref = definition.Ref,
			Tooltip = definition.Tooltip,
			TooltipOptions = definition.TooltipOptions,
			TooltipMaxWidth = definition.TooltipMaxWidth,
			TooltipOffset = definition.TooltipOffset,
			ChildOrder = definition.ChildOrder,
			Mode = "menu",
			Text = definition.Text,
			Disabled = definition.Disabled,
			Size = definition.Size or "M",
			Padding = definition.Padding or self._button_padding,
			OnClick = on_button_click,
			OnMouseEnter = on_button_enter,
		}
	end

	self:AddGlobalEvent("Update")
	self:AddGlobalEvent("KeyInput", {priority = math.huge})
end

function META:OnUpdate()
	if not self._context_menu:IsValid() then return end

	local mouse_pos = system.GetWindow():GetMousePosition()

	for index, button in ipairs(self._buttons) do
		if
			self._active_index ~= index and
			not button.Disabled and
			button.visual:IsHovered(mouse_pos)
		then
			self:OpenMenu(index)

			break
		end
	end
end

function META:OnKeyInput(key, press)
	if not self._context_menu:IsValid() then return end

	if press and key == "escape" then
		self:CloseMenu()
		return false
	end
end

function META:sync_button_state()
	for index, button in ipairs(self._buttons) do
		button:SetActive(self._active_index == index)
	end
end

function META:CloseMenu()
	if self._context_menu:IsValid() then self._context_menu:Remove() end

	self._context_menu = NULL
	self._active_index = nil
	self:sync_button_state()
	return self
end

function META:OpenMenu(index)
	local definition = self.Items[index]

	if not definition or definition.Disabled then return end

	local menu_items = definition.Items or {}

	if type(menu_items) == "function" then menu_items = menu_items() end

	local button = self._buttons[index]

	if #menu_items == 0 then
		self:CloseMenu()

		if definition.OnClick then definition.OnClick(button, self) end

		return
	end

	self._active_index = index
	self._context_menu:Remove()
	self._context_menu = Panel.OpenContextMenu(
		{
			Key = self.MenuKey,
			Anchor = button,
			AnchorPlacement = definition.AnchorPlacement or "below_left",
			SourceMenuBar = self,
			OnClose = on_menu_close,
		},
		unpack(menu_items)
	)
	self:sync_button_state()
end

return META:Register()
