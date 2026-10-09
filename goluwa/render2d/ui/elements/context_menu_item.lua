local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local SVG = import("goluwa/render2d/ui/elements/svg.lua")
local Icon = import("goluwa/render2d/ui/elements/icon.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("context_menu_item")
META.Base = Button
META.Mode = "menu"
META.CMP.transform = {Size = "M"}
META.CMP.layout = {
	Direction = "x",
	AlignmentY = "center",
	ChildGap = "S",
	FitWidth = false,
	FitHeight = true,
	GrowWidth = 1,
}
META:StartStorable()
META:GetSet("Selected", false)
META:GetSet("SelectedColor", nil)
META:GetSet("IconSource", nil)
META:GetSet("Items", nil)
META:EndStorable()

function META:SetSelected(selected)
	self.Selected = selected
	self:SetState("selected", selected)
	return self
end

function META:SetSelectedColor(color)
	self.SelectedColor = color
	self:SetState("selected_color", color)
	return self
end

function META:SetSubmenuOpen(open)
	self:SetActive(open)
	return self
end

function META.PropDefaults()
	return {
		Padding = theme.Dynamic(theme.ItemPadding),
		AlignX = 0,
		TextLayout = {
			GrowWidth = 1,
			MinSize = Vec2(10, 0),
			FitWidth = false,
			FitHeight = true,
		},
	}
end

function META:OnCreate()
	self._on_click = rawget(self, "OnClick")
	self.OnClick = nil
	META.BaseClass.OnCreate(self)
	self:SetSelected(self.Selected)
	self:SetSelectedColor(self.SelectedColor)

	if self.IconSource then
		self:AddChild(
			SVG{
				IsInternal = true,
				Source = self.IconSource,
				Size = "M",
				MinSize = "M",
				MaxSize = "M",
				Color = self.Disabled and "text_disabled" or "text",
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 0,
					FitWidth = false,
				},
			},
			1
		)
	end

	if self.Items then
		self.arrow = Icon{
			Parent = self,
			IsInternal = true,
			Icon = "disclosure",
			Size = "S",
			IconColor = self.Disabled and "text_disabled" or "text",
			layout = {
				GrowWidth = 0,
				FitWidth = false,
			},
		}
	end
end

function META:find_container()
	local current = self

	while current:IsValid() do
		if current.IsContextMenuContainer then return current end

		current = current:GetParent()
	end
end

function META:OnMouseEnter()
	local container = self:find_container()

	if not container then return end

	if not self.Disabled and self.Items then
		container:OpenSubmenu(self, self)
	else
		container:CloseFromLevel((self:GetParent().ContextMenuLevel or 1) + 1)
	end
end

function META:OnClick()
	if self.Items then
		self:find_container():OpenSubmenu(self, self)
		return true
	end

	local container = self:find_container()

	if container then container:RequestClose() end

	if self._on_click then return self._on_click(self) end
end

return META:Register()
