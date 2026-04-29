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

	local function get_surface_color()
		if state.disabled then return "clickable_disabled" end
		if state.mode == "outline" then return "surface" end
		if state.mode == "text" then return "surface" end
		if state.pressed then return "secondary" end
		if state.active then return theme.GetTheme():GetAccentTint(0.14) end
		if state.hovered then return theme.GetTheme():GetAccentTint(0.08) end

		return "primary"
	end

	local function sync_state(owner)
		state.disabled = not not owner.Disabled
		state.active = not not owner.Active
		state.mode = owner.Mode or "filled"
		owner.SurfaceColor = get_surface_color()
	end

	return Panel.New{
		props,
		{
			Name = "clickable",
			OnGetSurfaceColor = function(self)
				sync_state(self)
				return get_surface_color()
			end,
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
				BorderRadius = theme.GetRadius("medium"),
				ShadowSize = 10,
				ShadowColor = "clickable_shadow",
				ShadowOffset = Vec2(2, 2),
				Clipping = true,
				DrawAlpha = props.Disabled and 0.5 or 1,
				OnDraw = function(self)
					sync_state(self.Owner)
					self.DrawAlpha = state.disabled and 0.5 or 1
					state.pnl = self.Owner
					theme.active:DrawButton(self.Owner.transform:GetTotalSize(), state)
				end,
				OnPostDraw = function(self)
					sync_state(self.Owner)
					state.pnl = self.Owner
					theme.active:DrawButtonPost(self.Owner.transform:GetTotalSize(), state)
				end,
			},
			mouse_input = {
				Cursor = props.Disabled and "arrow" or "hand",
				OnMouseInput = function(self, button, press, local_pos)
					sync_state(self.Owner)
					self:SetCursor(state.disabled and "arrow" or "hand")
					if state.disabled then return end

					if button == "button_1" then
						state.pressed = press
						sync_state(self.Owner)
						theme.UpdateButtonAnimations(self.Owner, state)
					end
				end,
				OnHover = function(self, hovered)
					sync_state(self.Owner)
					self:SetCursor(state.disabled and "arrow" or "hand")
					state.hovered = hovered
					sync_state(self.Owner)
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
