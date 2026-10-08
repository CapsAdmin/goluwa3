local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("property_row")
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "x",
	GrowWidth = 1,
	AlignmentY = "center",
}
META.CMP.visual = {}
META.CMP.mouse_input = {}
META.CMP.clickable = {}
META:StartStorable()
META:GetSet("Editor", nil)
META:GetSet("Info", nil)
META:GetSet("Alternate", false)
META:GetSet("Selectable", false)
META:EndStorable()

function META:OnCreate(props)
	META.BaseClass.OnCreate(self, props)

	if self.Selectable then
		self.visual:SetClipping(true)
		self.mouse_input:SetCursor("pointer")
	end
end

function META:OnDraw()
	local info = self.Info
	self:SetState("selected", self.Selectable and self.Editor:GetSelectedKey() == info.key)
	self:SetState("alternate", self.Alternate)
	self:SetState("hovered", info.is_hovered)
	theme.active:Draw(self)

	if self.Selectable then
		local node = info.node

		if node.Default ~= nil and node.Value ~= node.Default then
			theme.active:DrawRoundRect(0, 0, 3, self.transform:GetSize().y, 0, theme.active:GetColor("primary"), 1)
		end
	end
end

function META:OnHover(hovered)
	self.Info.is_hovered = hovered
end

function META:OnMouseInput(button, press)
	if not press then return end

	if button == "button_2" then return self.Editor:open_context_menu(self.Info) end

	if button == "button_1" and self.Selectable then
		self.Editor:sync_selection(self.Info.key)
		return true
	end
end

return META:Register()
