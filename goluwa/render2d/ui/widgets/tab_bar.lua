local Panel = import("goluwa/render2d/ui/panel.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("tab_bar")
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "x",
	GrowWidth = 1,
	FitHeight = true,
	AlignmentY = "end",
	ChildGap = "XXS",
}
META.CMP.visual = {}
META:StartStorable()
META:GetSet("Tabs", nil)
META:GetSet("Value", nil)
META:GetSet("Font", nil)
META:GetSet("FontSize", nil)
META:EndStorable()

function META.OnChange(name, tab_bar) end

function META.PropDefaults(_, props)
	return {Tabs = {}}
end

local function on_tab_click(button)
	local tab_bar = button.TabBar

	if tab_bar.Value ~= button.TabName then
		tab_bar:SetValue(button.TabName)
		tab_bar.OnChange(button.TabName, tab_bar)
	end

	return true
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	self._buttons = {}
	self._ready = true
	self:rebuild_tabs()
end

function META:OnDraw()
	theme.active:Draw(self)
end

function META:rebuild_tabs()
	for _, button in ipairs(self._buttons) do
		button:Remove()
	end

	self._buttons = {}

	for _, name in ipairs(self.Tabs) do
		self._buttons[#self._buttons + 1] = Button{
			Parent = self,
			IsInternal = true,
			TabBar = self,
			TabName = name,
			Text = name,
			Mode = "tab",
			Font = self:GetPropertyToken("Font"),
			FontSize = self:GetPropertyToken("FontSize"),
			Active = name == self.Value,
			OnClick = on_tab_click,
		}
	end

	self.visual:SetVisible(self.Tabs[1] ~= nil)
	self.layout:InvalidateLayout()
end

function META:SetTabs(tabs)
	local changed = not table.equal(self.Tabs, tabs)
	self.Tabs = list.slice(tabs)

	if self._ready and changed then self:rebuild_tabs() end

	return self
end

function META:SetValue(name)
	self.Value = name

	if not self._ready then return self end

	for _, button in ipairs(self._buttons) do
		button:SetActive(button.TabName == name)
	end

	return self
end

return META:Register()
