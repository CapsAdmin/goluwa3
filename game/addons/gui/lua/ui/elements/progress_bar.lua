local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/ecs/panel.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	local pnl = Panel.New{
		props,
		Name = "progress_bar",
		transform = {
			Size = props.Size or Vec2(200, theme.GetSize("S")),
		},
		layout = {
			{
				MinSize = Vec2(100, theme.GetSize("M")),
			},
			props.layout,
		},
		gui_element = {
			DrawAlpha = 1,
			OnDraw = function(self)
				theme.active:Draw(self.Owner)
			end,
		},
	}
	pnl:SetState("value", props.Value or 0)
	pnl:SetState("color", props.Color)

	function pnl:SetValue(val)
		self:SetState("value", math.max(0, math.min(1, val)))
	end

	return pnl
end
