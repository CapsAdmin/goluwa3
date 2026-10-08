local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("clickable")
META.ThemeName = "clickable"
META.CMP.transform = {Perspective = 400}
META.CMP.layout = {
	Padding = "S",
	AlignmentX = "center",
	AlignmentY = "center",
}
META.CMP.visual = {Clipping = true}
META.CMP.mouse_input = {Cursor = "hand"}
META.CMP.style = {}
META.CMP.animation = {}
META.CMP.clickable = {}
META:StartStorable()
META:GetSet("Mode", "filled", {enums = {"filled", "outline", "text", "menu"}})
META:GetSet("ButtonColor", nil)
META:GetSet("Disabled", false)
META:GetSet("Active", false)
META:EndStorable()

function META:SetMode(mode)
	self.Mode = mode
	self:SetState("mode", mode)
	return self
end

function META:SetButtonColor(color)
	self.ButtonColor = color
	self:SetState("button_color", color)
	return self
end

function META:SetActive(active)
	self.Active = active
	self:SetState("active", active)
	return self
end

function META:SetDisabled(disabled)
	self.Disabled = disabled
	self.clickable:SetDisabled(disabled)
	self.visual:SetDrawAlpha(disabled and 0.5 or 1)
	self.mouse_input:SetCursor(disabled and "arrow" or "hand")
	self:SetState("disabled", disabled)
	return self
end

function META:OnCreate(props)
	META.BaseClass.OnCreate(self, props)
	self:SetState("hovered", false)
	self:SetState("pressed", false)
	self:SetMode(self.Mode)
	self:SetButtonColor(self.ButtonColor)
	self:SetActive(self.Active)
	self:SetDisabled(self.Disabled)
	self:update_style()
end

function META:update_style()
	local context = theme.active:ResolveButtonStyleContext(self:GetState())
	self.style:SetBackgroundColor(context.background_token)
	self.style:SetForegroundColor(context.foreground_token)
end

function META:OnStateChanged()
	self:update_style()
end

function META:OnStartClick()
	return true
end

function META:OnMouseInput(button, press)
	if self.Disabled then return end

	if button == "button_1" then self:SetState("pressed", press) end
end

function META:OnGlobalMouseInput(button, press)
	if button == "button_1" and not press then self:SetState("pressed", false) end
end

function META:OnHover(hovered)
	self:SetState("hovered", hovered)
end

function META:OnDraw()
	theme.active:Draw(self)
end

function META:OnPostDraw()
	theme.active:DrawPost(self)
end

return META:Register()
