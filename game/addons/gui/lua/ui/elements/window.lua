local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Frame = import("lua/ui/elements/frame.lua")
local Text = import("lua/ui/elements/text.lua")
local Button = import("lua/ui/elements/button.lua")
local TextButton = import("lua/ui/elements/text_button.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	local content
	return Panel.New{
		Name = props.Name or "Window",
		OnSetProperty = theme.OnSetProperty,
		transform = {
			Size = props.Size or Vec2(400, 300),
			Position = props.Position or Vec2(100, 100),
		},
		layout = {
			Direction = "y",
			AlignmentX = "stretch",
			Floating = true,
		},
		resizable = {
			MinimumSize = props.MinSize or Vec2(100, 100),
		},
		PreChildAdd = function(self, child)
			if child.IsInternal then return end

			if not content then return end

			content:AddChild(child)
			return false
		end,
		PreRemoveChildren = function(self)
			if not content then return end

			content:RemoveChildren()
			return false
		end,
		gui_element = true,
		mouse_input = true,
		clickable = true,
		animation = true,
	}{
		-- header
		Panel.New{
			IsInternal = true,
			Name = "WindowHeader",
			OnSetProperty = theme.OnSetProperty,
			layout = {
				Direction = "x",
				AlignmentY = "center",
				FitHeight = true,
				Padding = "XXXS",
			},
			gui_element = {
				Color = "primary",
				OnDraw = function(self)
					theme.panels.header(self.Owner)
				end,
			},
			draggable = true,
			mouse_input = {
				Cursor = "sizeall",
			},
			transform = true,
			clickable = true,
			animation = true,
			Events = {
				OnParent = function(self, parent)
					self.draggable:SetTarget(parent)
				end,
			},
		}{
			Text{
				Name = "Title",
				Text = props.Title or "Window",
				FontName = "heading",
				layout = {
					GrowWidth = 1,
					FitHeight = true,
				},
			},
			Button{
				Name = "CloseButton",
				Size = Vec2(20, 20),
				Color = theme.GetColor("negative"),
				OnClick = function(self)
					print("Close button clicked", props.OnClose, "?")

					if props.OnClose then
						props.OnClose(self:GetParent():GetParent())
					else
						self:GetParent():GetParent():Remove()
					end
				end,
				layout = {
					FitWidth = false,
					FitHeight = false,
				},
			},
		},
		-- content
		Panel.New{
			Ref = function(self)
				content = self
			end,
			IsInternal = true,
			Name = "WindowContent",
			OnSetProperty = theme.OnSetProperty,
			layout = {
				Direction = "y",
				GrowWidth = 1,
				GrowHeight = 1,
				Padding = Rect() + theme.GetPadding("M"),
			},
			gui_element = {
				Color = theme.GetColor("background"),
				OnDraw = function(self)
					theme.panels.frame(self.Owner)
				end,
				OnPostDraw = function(self)
					theme.panels.frame_post(self.Owner)
				end,
			},
			transform = true,
			mouse_input = true,
			clickable = true,
			animation = true,
		},
	}
end
