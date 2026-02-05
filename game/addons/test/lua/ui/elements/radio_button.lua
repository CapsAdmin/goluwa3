local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Rect = require("structs.rect")
local Panel = require("ecs.panel")
local theme = runfile("lua/ui/theme.lua")
local Text = runfile("lua/ui/elements/text.lua")
return function(props)
	local ent
	local state = {
		value = props.Selected or false,
		is_hovered = false,
		glow_alpha = 0,
		check_anim = props.Selected and 1 or 0,
		last_hovered = false,
		last_value = props.Selected or false,
	}
	ent = Panel.NewPanel(
		{
			Name = "radio_button_graphic",
			Size = props.Size or Vec2(theme.Sizes.RadioButtonSize, theme.Sizes.RadioButtonSize),
			Layout = props.Layout,
			Cursor = "hand",
			Color = Color(0, 0, 0, 0),
			mouse_input = {
				OnMouseInput = function(self, button, press, local_pos)
					if button == "button_1" and press then
						local selected = props.IsSelected and props.IsSelected() or state.value

						if not selected then
							if props.OnSelect then props.OnSelect() end

							state.value = true
							theme.UpdateCheckboxAnimations(ent, state)
						end

						return true
					end
				end,
			},
			OnHover = function(self, hovered)
				state.is_hovered = hovered
				theme.UpdateCheckboxAnimations(ent, state)
			end,
			gui_element = {
				OnDraw = function(self)
					if props.IsSelected then
						state.value = props.IsSelected()
					else
						state.value = props.Selected
					end

					theme.UpdateCheckboxAnimations(ent, state)
					theme.DrawRadioButton(self, state)
				end,
			},
		}
	)
	return ent
end
