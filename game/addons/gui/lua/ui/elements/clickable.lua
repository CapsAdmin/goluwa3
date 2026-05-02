local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Texture = import("goluwa/render/texture.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	local function update_style_context(panel)
		local style = panel.style

		if not style or not theme.active then return end

		style:SetBackgroundColor(theme.active:ResolveButtonBackgroundToken(panel:GetState()))
	end

	local panel = Panel.New{
		props,
		{
			Name = "clickable",
			OnStateChanged = function(self)
				update_style_context(self)
			end,
			style = props.style or true,
			transform = {
				Size = props.Size or Vec2(200, 50),
				Perspective = 400,
				DrawScaleOffset = Vec2(1, 1),
				DrawAngleOffset = Ang3(0, 0, 0),
			},
			layout = {
				Padding = "M",
				AlignmentX = "center",
				AlignmentY = "center",
				props.layout,
			},
			gui_element = {
				BorderRadius = theme.GetRadius("medium"),
				Clipping = true,
				OnDraw = function(self)
					self:SetDrawAlpha(self.Owner:GetState("disabled") and 0.5 or 1)
					theme.active:Draw(self.Owner)
				end,
				OnPostDraw = function(self)
					theme.active:DrawPost(self.Owner)
				end,
			},
			mouse_input = {
				Cursor = "hand",
				OnMouseInput = function(self, button, press, local_pos)
					self:SetCursor(self.Owner:GetState("disabled") and "arrow" or "hand")

					if self.Owner:GetState("disabled") then return end

					if button == "button_1" then self.Owner:SetState("pressed", press) end
				end,
				OnHover = function(self, hovered)
					self:SetCursor(self.Owner:GetState("disabled") and "arrow" or "hand")
					self.Owner:SetState("hovered", hovered)
				end,
			},
			animation = true,
			clickable = true,
			OnClick = not props.Disabled and props.OnClick or nil,
		},
	}
	panel:SetState("hovered", false)
	panel:SetState("pressed", false)
	panel:SetState("disabled", not not props.Disabled)
	panel:SetState("active", not not props.Active)
	panel:SetState("mode", props.Mode or "filled")
	panel:SetState("button_color", props.ButtonColor)
	update_style_context(panel)
	return panel
end
