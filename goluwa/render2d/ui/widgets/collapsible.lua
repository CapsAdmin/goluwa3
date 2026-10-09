local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Clickable = import("goluwa/render2d/ui/elements/clickable.lua")
local Icon = import("goluwa/render2d/ui/elements/icon.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("collapsible")
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "y",
	FitHeight = true,
	GrowWidth = 1,
}
META.CMP.visual = {}
META.CMP.animation = {}
META:StartStorable()
META:GetSet("Title", "")
META:GetSet("Collapsed", false)
META:GetSet("OpenFraction", 1)
META:GetSet("SlideTime", 0.3)
META:GetSet("HeaderMode", "outline")
META:GetSet("HeaderButtonColor", nil)
META:GetSet("HeaderTextColor", "text")
META:GetSet("HeaderFont", "body")
META:GetSet("HeaderFontSize", nil)
META:GetSet("HeaderHeight", nil)
META:GetSet("HeaderPadding", nil)
META:GetSet("HeaderGap", nil)

META:GetSet("Padding", nil, function(self, val)
	self._body.layout:SetPadding(val)
end)

META:EndStorable()

function META.OnToggle(collapsed, collapsible) end

local function on_header_click(header)
	header.Collapsible:SetCollapsed(not header.Collapsible.Collapsed)
	return true
end

local function on_container_changed(container)
	container.Collapsible:update_height()
end

local function get_open_fraction(collapsible)
	return collapsible.OpenFraction
end

local function set_open_fraction(value, collapsible)
	collapsible:SetOpenFraction(value)
end

function META:OnCreate()
	local tooltip = self.Tooltip
	local tooltip_max_width = self.TooltipMaxWidth
	self.Tooltip = nil
	self.TooltipMaxWidth = nil
	META.BaseClass.OnCreate(self)
	self.OpenFraction = self.Collapsed and 0 or 1
	local font_size = self.HeaderFontSize or "M"
	local header_height = self.HeaderHeight
	self._header = Clickable{
		Parent = self,
		IsInternal = true,
		Collapsible = self,
		Mode = self.HeaderMode,
		ButtonColor = self.HeaderButtonColor,
		Tooltip = tooltip,
		TooltipMaxWidth = tooltip_max_width,
		layout = {
			Direction = "x",
			AlignmentY = "center",
			FitHeight = true,
			MinSize = header_height and Vec2(0, header_height) or nil,
			MaxSize = header_height and Vec2(0, header_height) or nil,
			Padding = self.HeaderPadding or "S",
			ChildGap = self.HeaderGap or "M",
		},
		OnClick = on_header_click,
	}
	self._arrow = Icon{
		Parent = self._header,
		IsInternal = true,
		Icon = "disclosure",
		IconColor = self.HeaderTextColor,
		OpenFraction = self.OpenFraction,
		Size = Vec2() + theme.active:ResolveFontSize(font_size),
	}
	Text{
		Parent = self._header,
		IsInternal = true,
		Text = self.Title,
		Color = self.HeaderTextColor,
		Font = self.HeaderFont,
		FontSize = font_size,
		IgnoreMouseInput = true,
		layout = {
			GrowWidth = 1,
			FitHeight = true,
		},
	}
	self._clip = Panel.New{
		Parent = self,
		IsInternal = true,
		Name = "collapsible_clip",
		Collapsible = self,
		transform = {Size = Vec2(0, 0)},
		layout = {
			FitHeight = false,
			GrowWidth = 1,
		},
		visual = {Clipping = true},
		OnLayoutUpdated = on_container_changed,
		OnTransformChanged = on_container_changed,
	}
	self._body = Panel.New{
		Parent = self._clip,
		IsInternal = true,
		Name = "collapsible_body",
		Collapsible = self,
		layout = {
			Direction = "y",
			FitHeight = true,
			GrowWidth = 1,
			AlignmentX = "stretch",
			Floating = true,
			Padding = self.Padding or "S",
		},
		transform = true,
		visual = true,
		OnLayoutUpdated = on_container_changed,
	}
	self:update_height()
end

function META:OnThemeChanged()
	self._arrow.transform:SetSize(Vec2() + theme.active:ResolveFontSize(self.HeaderFontSize or "M"))
end

function META:PreChildAdd(child)
	if child.IsInternal then return end

	self._body:AddChild(child)
	return false
end

function META:PreRemoveChildren()
	self._body:RemoveChildren()
	return false
end

function META:update_height()
	local clip = self._clip.transform
	local body = self._body.transform
	local clip_w = clip:GetWidth()

	if body:GetWidth() ~= clip_w then body:SetWidth(clip_w) end

	local height = body:GetHeight()
	local target = height * self.OpenFraction
	clip:SetHeight(target)
	self._clip.visual:SetVisible(self.OpenFraction > 0.001)
	body:SetY(-(height - target))
end

function META:SetOpenFraction(fraction)
	self.OpenFraction = fraction
	self._arrow:SetOpenFraction(fraction)
	self:update_height()
	return self
end

function META:SetCollapsed(collapsed)
	self.Collapsed = collapsed

	if not self._clip then return self end

	self.animation:StopAnimations()
	self:update_height()
	self.animation:Animate{
		id = "collapsible_slide",
		get = get_open_fraction,
		set = set_open_fraction,
		to = collapsed and 0 or 1,
		time = self.SlideTime,
		interpolation = "outExpo",
	}
	self.OnToggle(collapsed, self)
	return self
end

return META:Register()
