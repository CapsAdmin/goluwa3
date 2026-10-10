local Panel = import("goluwa/render2d/ui/panel.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local TabBar = import("goluwa/render2d/ui/widgets/tab_bar.lua")
local META = Panel:CreateTemplate("tabs")
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "y",
	GrowWidth = 1,
	FitHeight = true,
	AlignmentX = "stretch",
}
META:StartStorable()
META:GetSet("Value", nil)
META:GetSet("Font", nil)
META:GetSet("FontSize", nil)
META:EndStorable()

function META.OnChange(name, tabs) end

local function on_bar_change(name, tab_bar)
	local tabs = tab_bar.TabsWidget
	tabs:SetValue(name)
	tabs.OnChange(name, tabs)
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	self._names = {}
	self._pages = {}
	self._bar = TabBar{
		Parent = self,
		IsInternal = true,
		TabsWidget = self,
		Value = self.Value,
		Font = self:GetPropertyToken("Font"),
		FontSize = self:GetPropertyToken("FontSize"),
		OnChange = on_bar_change,
	}
	self._content = Column{
		Parent = self,
		IsInternal = true,
		layout = {ChildGap = 0, AlignmentX = "stretch"},
	}
end

function META:PreChildAdd(child)
	if child.IsInternal then return end

	local name = assert(child.Tab, "a page of tabs needs a Tab name")
	self._content:AddChild(child)
	child:EnsureComponent("visual")
	self._pages[name] = child
	self._names[#self._names + 1] = name
	self._bar:SetTabs(self._names)

	if self.Value == nil then self.Value = name end

	self:SetValue(self.Value)
	return false
end

function META:PreRemoveChildren()
	self._content:RemoveChildren()
	self._pages = {}
	self._names = {}
	self._bar:SetTabs(self._names)
	return false
end

function META:SetValue(name)
	self.Value = name

	if not self._bar then return self end

	self._bar:SetValue(name)

	for page_name, page in pairs(self._pages) do
		page.visual:SetVisible(page_name == name)
	end

	self._content.layout:InvalidateLayout()
	return self
end

function META:GetPage(name)
	return self._pages[name]
end

return META:Register()
