local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Rect = require("structs.rect")
local Ang3 = require("structs.ang3")
local window = require("window")
local event = require("event")
local Panel = require("ecs.panel")
local theme = require("ui.theme")
return function(props)
	local state = {
		value = props.Value or 0.5,
		min = props.Min or 0,
		max = props.Max or 1,
		is_dragging = false,
		is_hovered = false,
		glow_alpha = 0,
		knob_scale = 1,
		last_hovered = false,
	}

	local function SetValueFromPosition(ent, x)
		local size = ent.transform:GetSize()
		local knob_width = 20
		local usable_width = size.x - knob_width
		local normalized = math.max(0, math.min(1, (x - knob_width / 2) / usable_width))
		state.value = state.min + normalized * (state.max - state.min)

		if props.OnChange then props.OnChange(state.value) end
	end

	return Panel.NewPanel(
		{
			Name = "slider",
			Size = props.Size or Vec2(200, 20),
			Layout = props.Layout,
			Cursor = "hand",
			Color = theme.GetColor("invisible"),
			mouse_input = {
				OnMouseInput = function(self, button, press, local_pos)
					if button == "button_1" then
						if press then
							state.is_dragging = true
							SetValueFromPosition(self.Owner, local_pos.x)
						end

						return true
					end
				end,
				OnGlobalMouseInput = function(self, button, press, mouse_pos)
					if button == "button_1" and not press and state.is_dragging then
						state.is_dragging = false
						return true
					end
				end,
			},
			OnHover = function(self, hovered)
				state.is_hovered = hovered
				theme.UpdateSliderAnimations(self, state)
			end,
			gui_element = {
				OnDraw = function(self)
					if state.is_dragging then
						local mpos = window.GetMousePosition()
						local lpos = self.Owner.transform:GlobalToLocal(mpos)
						SetValueFromPosition(self.Owner, lpos.x)
					end

					theme.DrawSlider(self, state)
				end,
			},
		}
	)
end
