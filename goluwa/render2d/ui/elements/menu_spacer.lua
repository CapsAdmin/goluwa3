local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("menu_spacer")
META.CMP.transform = {}
META.CMP.layout = {
	FitWidth = false,
	FitHeight = false,
}
META.CMP.visual = {}
META.CMP.mouse_input = {IgnoreMouseInput = true}
META:StartStorable()
META:GetSet("Vertical", false)
META:GetSet("Thickness", nil)
META:EndStorable()

local function get_spacer_size(active, thickness, vertical)
	thickness = active:ResolveSize(thickness or "XS")

	if vertical then return Vec2(thickness, 0) end

	return Vec2(0, thickness)
end

function META.PropDefaults(_, props)
	local vertical = props.Vertical
	return {
		Size = theme.Dynamic(get_spacer_size, props.Thickness, vertical),
		layout = {
			GrowWidth = vertical and 0 or 1,
			GrowHeight = vertical and 1 or 0,
		},
	}
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	self:SetState("vertical", self.Vertical)
end

function META:OnDraw()
	theme.active:Draw(self)
end

return META:Register()
