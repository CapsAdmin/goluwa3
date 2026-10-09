local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("property_divider")
META.CMP.transform = {}
META.CMP.layout = {
	Floating = true,
	GrowWidth = 0,
	GrowHeight = 1,
}
META.CMP.visual = {}
META.CMP.mouse_input = {Cursor = "horizontal_resize"}
META.CMP.clickable = {}
META.CMP.animation = {}
META:StartStorable()
META:GetSet("Editor", nil)
META:GetSet("Container", nil)
META:GetSet("Thickness", 8)
META:GetSet("RestAlpha", 1)
META:EndStorable()

local function on_container_changed(container)
	container.PropertyDivider:update_position()
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	self._dragging = false
	self._hovered = false
	self.transform:SetSize(Vec2(self.Thickness, 0))
	self.Container.PropertyDivider = self
	self.Container:AddLocalListener("OnTransformChanged", on_container_changed, self)
	self.Container:AddLocalListener("OnLayoutUpdated", on_container_changed, self)
	self:update_position()
	self:update_alpha()
end

function META:update_position()
	self.transform:SetPosition(Vec2(self.Editor:GetKeyWidth() - self.Thickness / 2, 0))
	self.transform:SetHeight(self.Container.transform:GetHeight())
end

function META:update_alpha()
	self.visual:SetDrawAlpha(self._dragging and 1 or self._hovered and 0.9 or self.RestAlpha)
end

function META:OnHover(hovered)
	self._hovered = hovered
	self:update_alpha()
end

function META:OnMouseInput(button, press)
	if button ~= "button_1" then return end

	self._dragging = press
	self:update_alpha()
	return true
end

function META:OnGlobalMouseInput(button, press)
	if button == "button_1" and not press and self._dragging then
		self._dragging = false
		self:update_alpha()
	end
end

function META:OnGlobalMouseMove(pos)
	if not self._dragging then
		if self.mouse_input:GetHovered() then
			self.mouse_input:SetCursor("horizontal_resize")
			return true
		end

		return
	end

	self.Editor:SetKeyWidth(math.max(10, self.Container.transform:GlobalToLocal(pos).x))
	self.mouse_input:SetCursor("horizontal_resize")
	return true
end

function META:OnDraw()
	theme.active:Draw(self)
end

return META:Register()
