local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Text = import("lua/ui/elements/text.lua")
local Clickable = import("lua/ui/elements/clickable.lua")
local theme = import("lua/ui/theme.lua")

local function get_passthrough_props(src)
	local out = {}

	if src.Key ~= nil then out.Key = src.Key end

	if src.Parent ~= nil then out.Parent = src.Parent end

	if src.Ref ~= nil then out.Ref = src.Ref end

	if src.ChildOrder ~= nil then out.ChildOrder = src.ChildOrder end

	return out
end

return function(props)
	local content
	return Panel.New{
		get_passthrough_props(props),
		Name = props.Name or "Window",
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
			layout = {
				Direction = "x",
				AlignmentY = "center",
				FitHeight = true,
				Padding = "XS",
			},
			gui_element = {
				OnDraw = function(self)
					theme.active:Draw(self.Owner)
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
			Clickable{
				Name = "CloseButton",
				Mode = "text",
				Size = Vec2() + theme.GetSize("M"),
				Padding = "XXXS",
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
			}{
				Panel.New{
					IsInternal = true,
					Name = "CloseIcon",
					transform = {
						Size = Vec2() + theme.GetSize("S"),
					},
					gui_element = {
						OnDraw = function(self)
							theme.active:DrawIcon(
								"close",
								self.Owner.transform:GetSize(),
								{
									size = 10,
									thickness = 2,
									color = theme.GetColor("text"),
								}
							)
						end,
					},
					mouse_input = {
						IgnoreMouseInput = true,
					},
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
			Padding = props.Padding,
			layout = {
				Direction = "y",
				GrowWidth = 1,
				GrowHeight = 1,
				Padding = Rect() + theme.GetPadding("M"),
			},
			gui_element = {
				OnDraw = function(self)
					theme.active:Draw(self.Owner)
				end,
				OnPostDraw = function(self)
					theme.active:DrawPost(self.Owner)
				end,
			},
			transform = true,
			mouse_input = true,
			clickable = true,
			animation = true,
		},
	}
end
