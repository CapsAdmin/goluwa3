local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Rect = require("structs.rect")
local Ang3 = require("structs.ang3")
local window = require("window")
local event = require("event")
local Panel = require("ecs.panel")
local theme = runfile("lua/ui/theme.lua")
return function(props)
	local ent
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

	local function SetValueFromPosition(x)
		local size = ent.transform:GetSize()
		local knob_width = 20
		local usable_width = size.x - knob_width
		local normalized = math.max(0, math.min(1, (x - knob_width / 2) / usable_width))
		state.value = state.min + normalized * (state.max - state.min)

		if props.OnChange then props.OnChange(state.value) end
	end

	ent = Panel.NewPanel(
		{
			Name = "slider",
			Position = props.Position or (not props.layout and Vec2(100, 100) or nil),
			Size = props.Size or theme.Sizes.SliderSize,
			layout = props.layout,
			Cursor = "hand",
			Color = theme.GetColor("invisible"),
			mouse_input = {
				OnMouseInput = function(self, button, press, local_pos)
					if button == "button_1" then
						if press then
							state.is_dragging = true
							SetValueFromPosition(local_pos.x)
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
				theme.UpdateSliderAnimations(ent, state)
			end,
			gui_element = {
				OnDraw = function(self)
					if state.is_dragging then
						local mpos = window.GetMousePosition()
						local lpos = self.Owner.transform:GlobalToLocal(mpos)
						SetValueFromPosition(lpos.x)
					end

					theme.DrawSlider(self, state)
				end,
			},
		}
	)
	return ent
end
