local Panel = import("goluwa/render2d/ui/panel.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local Icon = import("goluwa/render2d/ui/elements/icon.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local META = Panel:CreateTemplate("breadcrumb")
META.CMP.transform = {}
META.CMP.visual = {}
META.CMP.layout = {
	Direction = "x",
	GrowWidth = 1,
	FitHeight = true,
	AlignmentY = "center",
	ChildGap = "XXXS",
}
META:StartStorable()
META:GetSet("Items", nil)
META:GetSet("Icons", nil)
META:GetSet("Font", nil)
META:GetSet("FontSize", nil)
META:EndStorable()

function META.OnSelect(index, breadcrumb) end

function META.PropDefaults(_, props)
	return {Items = {}}
end

local function on_crumb_click(button)
	local breadcrumb = button.Breadcrumb
	breadcrumb.OnSelect(button.Index, breadcrumb)
	return true
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	self._crumbs = {}
	self._ready = true
	self:rebuild_crumbs()
end

function META:rebuild_crumbs()
	for _, crumb in ipairs(self._crumbs) do
		crumb:Remove()
	end

	self._crumbs = {}
	local count = #self.Items

	for index, name in ipairs(self.Items) do
		if index > 1 then
			self._crumbs[#self._crumbs + 1] = Icon{
				Parent = self,
				IsInternal = true,
				Icon = "chevron_right",
				Size = "icon",
				MinSize = "icon",
				MaxSize = "icon",
				IconColor = "text_disabled",
				layout = {GrowWidth = 0, FitWidth = false},
			}
		end

		if index == count then
			self._crumbs[#self._crumbs + 1] = Text{
				Parent = self,
				IsInternal = true,
				Text = name,
				Font = self.Font or "body_strong",
				FontSize = self.FontSize or "S",
				Color = "primary",
				IgnoreMouseInput = true,
				layout = {Padding = "XXS"},
			}
		else
			self._crumbs[#self._crumbs + 1] = Button{
				Parent = self,
				IsInternal = true,
				Breadcrumb = self,
				Index = index,
				Text = name,
				Icon = self.Icons and self.Icons[name],
				Mode = "menu",
				Padding = "XXS",
				Font = self:GetPropertyToken("Font"),
				FontSize = self:GetPropertyToken("FontSize") or "S",
				OnClick = on_crumb_click,
			}
		end
	end

	self.visual:SetVisible(self.Items[1] ~= nil)
	self.layout:InvalidateLayout()
end

function META:SetItems(items)
	local changed = not table.equal(self.Items, items)
	self.Items = list.slice(items)

	if self._ready and changed then self:rebuild_crumbs() end

	return self
end

return META:Register()
