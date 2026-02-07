local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Color = require("structs.color")
local Panel = require("ecs.panel")
local Frame = require("ui.elements.frame")
local Text = require("ui.elements.text")
local Button = require("ui.elements.button")
local TextButton = require("ui.elements.text_button")
local theme = require("ui.theme")
return function(props)
	local window_container = Panel.NewPanel(
		{
			Name = props.Name or "Window",
			Size = props.Size or Vec2(400, 300),
			Color = theme.GetColor("invisible"),
			Position = props.Position or Vec2(100, 100),
			layout = {
				Direction = "y",
				AlignmentX = "stretch",
				Floating = true,
			},
		}
	)
	window_container:AddComponent("resizable")
	window_container.resizable:SetMinimumSize(props.MinSize or Vec2(100, 100))
	local title_val = props.Title or "Window"
	local header = Frame(
		{
			IsInternal = true,
			Name = "WindowHeader",
			Parent = window_container,
			layout = {
				Direction = "x",
				AlignmentY = "center",
				FitHeight = true,
			},
			Color = theme.GetColor("primary"),
			draggable = {Target = window_container},
			Cursor = "sizeall",
			Padding = "XXXS",
			Children = {
				Text(
					{
						Name = "Title",
						Text = title_val,
						layout = {
							GrowWidth = 1,
							FitHeight = true,
						},
					}
				),
				TextButton(
					{
						Name = "CloseButton",
						Text = "X",
						Size = Vec2(20, 20),
						OnClick = function()
							print("CLOSE WINDOW")

							if props.OnClose then
								props.OnClose(window_container)
							else
								window_container:Remove()
							end
						end,
						layout = {
							FitWidth = false,
							FitHeight = false,
						},
					}
				),
			},
		}
	)
	local content = Frame(
		{
			IsInternal = true,
			Name = "WindowContent",
			Parent = window_container,
			layout = {
				Direction = "y",
				GrowWidth = 1,
				GrowHeight = 1,
			},
			Padding = props.Padding or "M",
			Children = props.Children or {},
		}
	)

	function window_container:PreChildAdd(child)
		if child.IsInternal then return end

		content:AddChild(child)
		return false
	end

	function window_container:PreRemoveChildren()
		content:RemoveChildren()
		return false
	end

	return window_container
end
