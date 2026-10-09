local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Clickable = import("goluwa/render2d/ui/elements/clickable.lua")
local Icon = import("goluwa/render2d/ui/elements/icon.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local Dock = import("goluwa/render2d/ui/widgets/dock.lua")
local META = Panel:CreateTemplate("window")
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "y",
	AlignmentX = "stretch",
	Floating = true,
}
META.CMP.resizable = {BringToFrontOnResize = true}
META.CMP.visual = {}
META.CMP.mouse_input = {BringToFrontOnClick = true}
META.CMP.clickable = {}
META.CMP.animation = {}
META.CMP.snappable = {}
META:StartStorable()
META:GetSet("Title", "Window")
META:GetSet("Minimizable", true)
META:GetSet("Maximizable", true)
META:GetSet("Closable", true)
META:GetSet("MinSize", nil)
META:GetSet("Padding", nil)
META:EndStorable()

function META:OnClose()
	self:Remove()
end

local function on_header_draw(header)
	theme.active:Draw(header)
end

local function on_content_draw(content)
	theme.active:Draw(content)
end

local function on_content_post_draw(content)
	theme.active:DrawPost(content)
end

local function on_header_button_click(button)
	local window = button.Window
	window[button.Action](window)
end

local function on_header_drag(header, delta, pos)
	return header.Window.snappable:HandleDrag(header.draggable, delta, pos)
end

local function on_header_drag_stopped(header)
	header.Window.snappable:HandleDrop()
end

local function on_header_double_click(header)
	if header.Window.Maximizable then header.Window:ToggleMaximize() end
end

local function restore_from_dock(window)
	window:Restore()
end

local function remove_from_dock(window)
	if window._minimized then Dock.GetInstance():RemoveItem(window) end
end

local header_buttons = {
	{Prop = "Minimizable", Icon = "minimize", Action = "Minimize"},
	{Prop = "Maximizable", Icon = "maximize", Action = "ToggleMaximize"},
	{Prop = "Closable", Icon = "close", Action = "OnClose"},
}

function META:OnCreate(props)
	props.Size = props.Size or Vec2(400, 300)
	props.Position = props.Position or Vec2(100, 100)
	META.BaseClass.OnCreate(self, props)
	self.resizable:SetMinimumSize(self.MinSize or Vec2(100, 100))
	self._minimized = false
	self:CallOnRemove(remove_from_dock, "window_dock")
	self._header = Panel.New{
		Parent = self,
		IsInternal = true,
		Name = "window_header",
		Window = self,
		transform = true,
		layout = {
			Direction = "x",
			AlignmentY = "center",
			FitHeight = true,
			Padding = "XS",
		},
		visual = true,
		draggable = true,
		mouse_input = {Cursor = "sizeall"},
		clickable = true,
		animation = true,
		OnDraw = on_header_draw,
		OnDrag = on_header_drag,
		OnDragStopped = on_header_drag_stopped,
		OnDoubleClick = on_header_double_click,
	}
	self._header.draggable:SetTarget(self)
	self._title = Text{
		Parent = self._header,
		IsInternal = true,
		Text = self.Title,
		Font = "heading",
		IgnoreMouseInput = true,
		layout = {
			GrowWidth = 1,
			FitHeight = true,
		},
	}
	self._header_icons = {}

	for _, definition in ipairs(header_buttons) do
		if self[definition.Prop] then
			local button = Clickable{
				Parent = self._header,
				IsInternal = true,
				Window = self,
				Action = definition.Action,
				Mode = "text",
				Size = "M",
				layout = {
					Padding = "XXXS",
					FitWidth = false,
					FitHeight = false,
				},
				OnClick = on_header_button_click,
			}
			self._header_icons[definition.Icon] = Icon{
				Parent = button,
				IsInternal = true,
				Icon = definition.Icon,
				Size = "S",
			}
		end
	end

	self._content = Panel.New{
		Parent = self,
		IsInternal = true,
		Name = "window_content",
		transform = true,
		layout = {
			Direction = "y",
			GrowWidth = 1,
			GrowHeight = 1,
			Padding = self.Padding or "M",
		},
		visual = true,
		mouse_input = true,
		clickable = true,
		animation = true,
		OnDraw = on_content_draw,
		OnPostDraw = on_content_post_draw,
	}
end

function META:SetTitle(title)
	self.Title = title

	if self._title then self._title.text:SetText(title) end

	if self._minimized then Dock.GetInstance():SetItemText(self, title) end

	return self
end

function META:IsMinimized()
	return self._minimized
end

function META:IsMaximized()
	return self.snappable:GetSnappedZone() == "maximize"
end

function META:Minimize()
	if self._minimized then return self end

	self._minimized = true
	self.visual:SetVisible(false)
	Dock.GetInstance():AddItem(self, self.Title, restore_from_dock)
	return self
end

function META:Maximize()
	if self._minimized then self:Restore() end

	self.snappable:Snap("maximize")
	return self
end

function META:Restore()
	if self._minimized then
		self._minimized = false
		Dock.GetInstance():RemoveItem(self)
		self.visual:SetVisible(true)
		self:BringToFront()
	else
		self.snappable:Unsnap()
	end

	return self
end

function META:ToggleMaximize()
	if self:IsMaximized() then return self:Restore() end

	return self:Maximize()
end

function META:OnSnapChanged(zone)
	local icon = self._header_icons.maximize

	if icon then icon:SetIcon(zone == "maximize" and "restore" or "maximize") end
end

function META:PreChildAdd(child)
	if child.IsInternal then return end

	self._content:AddChild(child)
	return false
end

function META:PreRemoveChildren()
	self._content:RemoveChildren()
	return false
end

return META:Register()
