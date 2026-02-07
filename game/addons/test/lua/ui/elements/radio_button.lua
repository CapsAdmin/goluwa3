local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Rect = require("structs.rect")
local Panel = require("ecs.panel")
local theme = require("ui.theme")
local Text = require("ui.elements.text")
return function(props)
	local state = {
		value = props.Selected or false,
		is_hovered = false,
		glow_alpha = 0,
		check_anim = props.Selected and 1 or 0,
		last_hovered = false,
		last_value = props.Selected or false,
	}
	return Panel.NewPanel(
		{
			Name = "radio_button_graphic",
			Size = props.Size or (Vec2() + theme.GetSize("M")),
			layout = props.layout,
			Cursor = "hand",
			Color = theme.GetColor("invisible"),
			mouse_input = {
				OnMouseInput = function(self, button, press, local_pos)
					if button == "button_1" and press then
						local selected = props.IsSelected and props.IsSelected() or state.value

						if not selected then
							if props.OnSelect then props.OnSelect() end

							state.value = true
							theme.UpdateCheckboxAnimations(self.Owner, state)
						end

						return true
					end
				end,
			},
			OnHover = function(self, hovered)
				state.is_hovered = hovered
				theme.UpdateCheckboxAnimations(self, state)
			end,
			gui_element = {
				OnDraw = function(self)
					if props.IsSelected then
						state.value = props.IsSelected()
					else
						state.value = props.Selected
					end

					theme.UpdateCheckboxAnimations(self.Owner, state)
					theme.DrawRadioButton(self.Owner, state)
				end,
			},
		}
	)
end
