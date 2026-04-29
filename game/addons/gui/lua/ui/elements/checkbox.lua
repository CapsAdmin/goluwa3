local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/ecs/panel.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	local value = props.Value ~= nil and props.Value or false
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
	local panel = Panel.New{
		Name = "checkbox_graphic",
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
					state.value = not state.value

					if props.OnChange then props.OnChange(state.value) end

					theme.UpdateCheckboxAnimations(self.Owner, state)
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
				theme.UpdateCheckboxAnimations(self.Owner, state)
				theme.active:DrawCheckbox(self.Owner.transform:GetSize(), state)
			end,
		},
		animation = true,
		clickable = true,
	}

	function panel:SetValue(new_value, notify)
		local old_value = state.value
		state.value = new_value == true
		theme.UpdateCheckboxAnimations(self, state)

		if notify and old_value ~= state.value and props.OnChange then
			props.OnChange(state.value, old_value)
		end

		return self
	end

	function panel:GetValue()
		return state.value
	end

	panel:SetValue(value)
	return panel
end
