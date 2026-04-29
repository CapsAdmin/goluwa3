local render2d = import("goluwa/render2d/render2d.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Texture = import("goluwa/render/texture.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	local state = {
		hovered = false,
		pressed = false,
		disabled = not not props.Disabled,
		active = not not props.Active,
		mode = props.Mode or "filled",
		anim = {
			glow_alpha = 0,
			press_scale = 0,
			last_hovered = false,
			last_pressed = false,
			last_active = false,
			last_tilting = false,
		},
	}
	return Panel.New{
		props,
		{
			Name = "clickable",
			OnSetProperty = theme.OnSetProperty,
			transform = {
				Size = props.Size or Vec2(200, 50),
				Perspective = 400,
				DrawScaleOffset = Vec2(1, 1),
				DrawAngleOffset = Ang3(0, 0, 0),
			},
			layout = {
				Padding = "XXS",
				AlignmentX = "center",
				AlignmentY = "center",
				props.layout,
			},
			gui_element = {
				Shadows = false,
				BorderRadius = 10,
				ShadowSize = 10,
				ShadowColor = "clickable_shadow",
				ShadowOffset = Vec2(2, 2),
				Clipping = true,
				DrawAlpha = props.Disabled and 0.5 or 1,
				OnDraw = function(self)
					state.pnl = self.Owner
					theme.active:DrawButton(self.Owner.transform:GetTotalSize(), state)
				end,
				OnPostDraw = function(self)
					state.pnl = self.Owner
					theme.active:DrawButtonPost(self.Owner.transform:GetTotalSize(), state)
				end,
			},
			mouse_input = {
				Cursor = props.Disabled and "arrow" or "hand",
				OnMouseInput = function(self, button, press, local_pos)
					if props.Disabled then return end

					if button == "button_1" then
						state.pressed = press
						theme.UpdateButtonAnimations(self.Owner, state)
					end
				end,
				OnHover = function(self, hovered)
					state.hovered = hovered
					theme.UpdateButtonAnimations(self.Owner, state)
				end,
			},
			animation = true,
			clickable = true,
			OnClick = not props.Disabled and
				(
					props.OnClick or
					function()
						print("clicked!")
					end
				)
				or
				nil,
		},
	}
end
