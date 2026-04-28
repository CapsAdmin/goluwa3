local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Rect = import("goluwa/structs/rect.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local Panel = import("goluwa/ecs/panel.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	local mode = props.Mode or "horizontal"
	local state = {
		mode = mode,
		hovered = false,
		dragging = false,
		anim = {
			glow_alpha = 0,
			knob_scale = 1,
			last_hovered = false,
		},
	}

	if mode == "2d" then
		state.value = props.Value or Vec2(0.5, 0.5)
		state.min = props.Min or Vec2(0, 0)
		state.max = props.Max or Vec2(1, 1)
	else
		state.value = props.Value or 0.5
		state.min = props.Min or 0
		state.max = props.Max or 1
	end

	local function SetValueFromPosition(ent, local_pos)
		local size = ent.transform:GetSize()
		local knob_size = theme.GetSize("S")

		if state.mode == "2d" then
			local usable_width = size.x - knob_size
			local usable_height = size.y - knob_size

			if usable_width <= 0 or usable_height <= 0 then return end

			local nx = math.max(0, math.min(1, (local_pos.x - knob_size / 2) / usable_width))
			local ny = math.max(0, math.min(1, (local_pos.y - knob_size / 2) / usable_height))
			state.value = Vec2(
				state.min.x + nx * (state.max.x - state.min.x),
				state.min.y + ny * (state.max.y - state.min.y)
			)
		elseif state.mode == "vertical" then
			local usable_height = size.y - knob_size

			if usable_height <= 0 then return end

			local normalized = math.max(0, math.min(1, (local_pos.y - knob_size / 2) / usable_height))
			state.value = state.min + normalized * (state.max - state.min)
		else
			local usable_width = size.x - knob_size

			if usable_width <= 0 then return end

			local normalized = math.max(0, math.min(1, (local_pos.x - knob_size / 2) / usable_width))
			state.value = state.min + normalized * (state.max - state.min)
		end

		if props.OnChange then props.OnChange(state.value) end
	end

	return Panel.New{
		props,
		Name = "slider",
		OnSetProperty = theme.OnSetProperty,
		transform = {
			Size = state.mode == "vertical" and
				Vec2(theme.GetSize("S"), 100) or
				(
					state.mode == "2d" and
					Vec2(100, 100) or
					Vec2(100, theme.GetSize("S"))
				),
		},
		layout = {
			{
				MinSize = state.mode == "vertical" and
					Vec2(theme.GetSize("S"), 100) or
					(
						state.mode == "2d" and
						Vec2(100, 100) or
						Vec2(100, theme.GetSize("S"))
					),
			},
			props.layout,
		},
		mouse_input = {
			Cursor = "hand",
			OnMouseInput = function(self, button, press, local_pos)
				if button == "button_1" then
					if press then
						state.dragging = true
						SetValueFromPosition(self.Owner, local_pos)
					end

					return true
				end
			end,
			OnGlobalMouseInput = function(self, button, press, mouse_pos)
				if button == "button_1" and not press and state.dragging then
					state.dragging = false
					return true
				end
			end,
			OnHover = function(self, hovered)
				state.hovered = hovered
				theme.UpdateSliderAnimations(self.Owner, state)
			end,
		},
		gui_element = {
			OnDraw = function(self)
				if state.dragging then
					local mpos = system.GetWindow():GetMousePosition()
					local lpos = self.Owner.transform:GlobalToLocal(mpos)
					SetValueFromPosition(self.Owner, lpos)
				end

				theme.active:DrawSlider(self, state)
			end,
		},
		animation = true,
		clickable = true,
	}
end
