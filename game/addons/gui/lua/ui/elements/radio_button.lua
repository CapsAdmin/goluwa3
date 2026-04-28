local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/ecs/panel.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	local value = props.Selected ~= nil and props.Selected or false
	local state = {
		hovered = false,
		value = value,
		anim = {
			glow_alpha = 0,
			check_anim = value and 1 or 0,
			last_hovered = false,
			last_value = value,
		},
	}
	return Panel.New{
		props,
		{
			Name = "radio_button_graphic",
			OnSetProperty = theme.OnSetProperty,
			transform = {
				Size = props.Size or "M",
			},
			layout = {
				props.layout,
			},
			mouse_input = {
				Cursor = "hand",
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
				OnHover = function(self, hovered)
					state.hovered = hovered
					theme.UpdateCheckboxAnimations(self.Owner, state)
				end,
			},
			gui_element = {
				OnDraw = function(self)
					if props.IsSelected then
						state.value = props.IsSelected()
					else
						state.value = props.Selected
					end

					theme.UpdateCheckboxAnimations(self.Owner, state)
					theme.active:DrawButtonRadio(self.Owner, state)
				end,
			},
			animation = true,
			clickable = true,
		},
	}
end
