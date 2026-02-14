local Vec2 = require("structs.vec2")
local Panel = require("ecs.panel")
local theme = require("ui.theme")
return function(props)
	local state = {
		value = props.Value or 0,
	}
	local pnl = Panel.New(
		{
			props,
			Name = "progress_bar",
			OnSetProperty = theme.OnSetProperty,
			transform = {
				Size = props.Size or Vec2(200, theme.GetSize("S")),
			},
			layout = {
				{
					MinSize = Vec2(100, theme.GetSize("XXS")),
				},
				props.layout,
			},
			gui_element = {
				DrawAlpha = 1,
				OnDraw = function(self)
					theme.panels.progress_bar(self, state)
				end,
				Color = props.Color or "primary",
			},
		}
	)
	pnl.ProgressBarState = state

	function pnl:SetValue(val)
		state.value = math.max(0, math.min(1, val))
	end

	return pnl
end
