local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local META = Panel:CreateTemplate("colllapsible")
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "y",
	FitHeight = true,
	GrowWidth = 1,
}
META.CMP.gui_element = {}
META.CMP.animation = {}
META:GetSet("OpenFraction", 1)
META:GetSet("Collapsed", false)

META:GetSet("Padding", Rect(), function(self, val)
	self.body_panel.layout:SetPadding(val)
end)

function META.OnToggle(b) end

function META:OnCreate(props)
	self.BaseClass.OnCreate(self, props)
	self:AddChild(props.Header)
	self.clip_panel = Panel.New{
		Parent = self,
		IsInternal = true,
		Name = "ClipContainer",
		OnLayoutUpdated = function()
			self:UpdateHeight()
		end,
		OnTransformChanged = function()
			self:UpdateHeight()
		end,
		transform = {
			Size = Vec2(0, 0),
		},
		layout = {
			FitHeight = false,
			GrowWidth = 1,
		},
		gui_element = {
			Clipping = true,
		},
	}
	self.body_panel = Panel.New{
		Parent = self.clip_panel,
		IsInternal = true,
		Name = "Body",
		layout = {
			Direction = "y",
			FitHeight = true,
			GrowWidth = 1,
			AlignmentX = "stretch",
			Floating = true,
		},
		transform = true,
		gui_element = true,
		OnLayoutUpdated = function()
			self:UpdateHeight()
		end,
	}
	self:SetOpenFraction(self:GetCollapsed() and 0 or 1)
	self:SetCollapsed(props.Collapsed)
	self:UpdateHeight()
end

function META:PreChildAdd(child)
	if child.IsInternal then return end

	self.body_panel:AddChild(child)
	return false
end

function META:PreRemoveChildren()
	self.body_panel:RemoveChildren()
	return false
end

function META:UpdateHeight()
	local clip_w = self.clip_panel.transform:GetWidth()
	local body_w = self.body_panel.transform:GetWidth()

	if body_w ~= clip_w then self.body_panel.transform:SetWidth(clip_w) end

	local h = self.body_panel.transform:GetHeight()
	local target_h = h * self:GetOpenFraction()
	local target_y = -(h - target_h)
	self.clip_panel.transform:SetHeight(target_h)
	self.clip_panel.gui_element:SetVisible(self:GetOpenFraction() > 0.001)
	self.body_panel.transform:SetY(target_y)
end

function META:SetCollapsed(value)
	self.Collapsed = value
	self.animation:Animate{
		id = "collapsible_slide",
		get = function()
			return self:GetOpenFraction()
		end,
		set = function(v)
			self:SetOpenFraction(v)
			self:UpdateHeight()
		end,
		to = self:GetCollapsed() and 0 or 1,
		time = 0.3,
		interpolation = "outExpo",
	}
	self.OnToggle(self:GetCollapsed())
	return self
end

META:Register()
return META.New
