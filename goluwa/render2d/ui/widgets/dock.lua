local Vec2 = import("goluwa/structs/vec2.lua")
local system = import("goluwa/system.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("dock")
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "x",
	AlignmentY = "center",
	Floating = true,
	FitWidth = true,
	FitHeight = true,
	Padding = "XS",
	ChildGap = "XS",
}
META.CMP.visual = {Visible = false}
META.CMP.mouse_input = {}
META:StartStorable()
META:GetSet("ShowDistance", 24)
META:GetSet("HideDelay", 0.6)
META:GetSet("SlideSpeed", 14)
META:GetSet("Margin", "M")
META:EndStorable()
local instance

function META.GetInstance()
	if not instance or not instance:IsValid() then
		instance = META.New{Parent = Panel.World}
	end

	return instance
end

local function on_item_click(button)
	button.Tray:ActivateItem(button.DockItem)
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	self._items = {}
	self._callbacks = {}
	self._count = 0
	self._fraction = 0
	self._reveal_until = 0
	self:AddGlobalEvent("Update")
end

function META:AddItem(key, text, on_activate)
	assert(not self._items[key], "dock item already exists")
	self._items[key] = Button{
		Parent = self,
		IsInternal = true,
		Mode = "outline",
		Text = text,
		Tray = self,
		DockItem = key,
		OnClick = on_item_click,
	}
	self._callbacks[key] = on_activate
	self._count = self._count + 1
	self:Reveal()
end

function META:RemoveItem(key)
	self._items[key]:Remove()
	self._items[key] = nil
	self._callbacks[key] = nil
	self._count = self._count - 1
end

function META:HasItem(key)
	return self._items[key] ~= nil
end

function META:SetItemText(key, text)
	self._items[key]:SetText(text)
end

function META:ActivateItem(key)
	self._callbacks[key](key)
end

function META:Reveal(seconds)
	self._reveal_until = system.GetElapsedTime() + (seconds or 1.5)
end

function META:OnUpdate()
	local visual = self.visual

	if self._count == 0 then
		self._fraction = 0
		visual:SetVisible(false)
		return
	end

	local transform = self.transform
	local world_size = Panel.World.transform:GetSize()
	local size = transform:GetSize()
	local margin = theme.active:ResolveSize(self.Margin)
	local mouse = system.GetWindow():GetMousePosition()
	local now = system.GetElapsedTime()
	local shown_y = world_size.y - size.y - margin
	local target = 0

	if
		mouse.y >= world_size.y - self.ShowDistance or
		self._fraction > 0.01 and
		mouse.y >= shown_y and
		mouse.x >= transform.Position.x and
		mouse.x <= transform.Position.x + size.x
	then
		self._hold_until = now + self.HideDelay
	end

	if now < self._reveal_until or now < (self._hold_until or 0) then target = 1 end

	local previous = self._fraction
	self._fraction = previous + (
			target - previous
		) * math.min(1, system.GetFrameTime() * self.SlideSpeed)

	if target == 0 and self._fraction < 0.01 then
		self._fraction = 0
		visual:SetVisible(false)
		return
	end

	if previous == 0 then
		visual:SetVisible(true)
		self:BringToFront()
	end

	transform:SetPosition(
		Vec2((world_size.x - size.x) / 2, world_size.y + (shown_y - world_size.y) * self._fraction)
	)
end

function META:OnDraw()
	theme.active:Draw(self)
end

return META:Register()
