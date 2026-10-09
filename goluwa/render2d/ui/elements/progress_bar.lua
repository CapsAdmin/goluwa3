local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("progress_bar")
META.CMP.transform = {}
META.CMP.layout = {}
META.CMP.visual = {}
META:StartStorable()
META:GetSet("Value", 0)
META:GetSet("Color", nil)
META:EndStorable()

function META:SetValue(val)
	self.Value = math.clamp(val, 0, 1)
	self:SetState("value", self.Value)
end

local function get_bar_size(active, width)
	return Vec2(width, active:GetSize("M"))
end

function META.PropDefaults()
	return {
		Size = theme.Dynamic(get_bar_size, 200),
		layout = {MinSize = theme.Dynamic(get_bar_size, 100)},
	}
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	self:SetValue(self.Value)
	self:SetState("color", self.Color)
end

function META:OnDraw()
	theme.active:Draw(self)
end

return META:Register()
