local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Text = require("ui.elements.text")
local Slider = require("ui.elements.slider")
local Row = require("ui.elements.row")
local Column = require("ui.elements.column")
local theme = require("ui.theme")
local Color = require("structs.color")
return {
	Name = "Extended Sliders",
	Create = function()
		local canvas = Column(
			{
				layout = {
					Direction = "y",
					FitHeight = true,
					GrowWidth = 1,
					ChildGap = 20,
					AlignmentX = "start",
				},
			}
		)
		canvas.layout:SetPadding(
			Rect(
				theme.GetPadding("M"),
				theme.GetPadding("M"),
				theme.GetPadding("M"),
				theme.GetPadding("M")
			)
		)
		canvas.state = {
			hue = 0,
			sat = 1,
			val = 0.5,
		}
		-- 2D Color Picker Demo
		canvas:AddChild(
			Text({Text = "2D Color Picker Demo", FontName = "heading", Size = theme.GetSize("L")})
		)
		local preview_box = Column(
			{
				layout = {
					MinSize = Vec2(100, 100),
				},
				rect = {
					Color = Color(1, 0.5, 0.5, 1),
				},
			}
		)

		local function update_preview()
			local hue = canvas.state.hue or 0
			local sat = canvas.state.sat or 1
			local val = canvas.state.val or 0.5
			preview_box.rect.Color = Color.FromHSV(hue, sat, val):SetAlpha(1)
		end

		local picker_row = Row(
			{
				layout = {
					Direction = "x",
					ChildGap = 20,
					AlignmentY = "start",
					FitHeight = true,
					GrowWidth = 1,
				},
			}
		)(
			{
				Column({
					layout = {Direction = "y", ChildGap = 5, FitHeight = true},
				})(
					{
						Text({Text = "Saturation/Value (2D)"}),
						Slider(
							{
								Mode = "2d",
								Value = Vec2(1, 0.5),
								OnChange = function(val)
									canvas.state.sat = val.x
									canvas.state.val = val.y
									update_preview()
								end,
								layout = {MinSize = Vec2(200, 200)},
							}
						),
					}
				),
				Column({
					layout = {Direction = "y", ChildGap = 5, FitHeight = true},
				})(
					{
						Text({Text = "Hue"}),
						Slider(
							{
								Mode = "vertical",
								Value = 0,
								Min = 0,
								Max = 1,
								OnChange = function(val)
									canvas.state.hue = val
									update_preview()
								end,
								layout = {MinSize = Vec2(theme.GetSize("S"), 200)},
							}
						),
					}
				),
				Column({
					layout = {Direction = "y", ChildGap = 5, AlignmentX = "center"},
				})({
					Text({Text = "Preview"}),
					preview_box,
				}),
			}
		)
		canvas:AddChild(picker_row)
		-- Mixing various orientations
		canvas:AddChild(
			Text({Text = "Orientation Layouts", FontName = "heading", Size = theme.GetSize("L")})
		)
		canvas:AddChild(
			Row(
				{
					layout = {Direction = "x", ChildGap = 40, AlignmentY = "center", FitHeight = true},
				}
			)(
				{
					Column({layout = {Direction = "y", ChildGap = 10, AlignmentX = "center"}})(
						{
							Text({Text = "Vol"}),
							Slider({Mode = "vertical", Value = 0.8, layout = {MinSize = Vec2(20, 150)}}),
						}
					),
					Column({layout = {Direction = "y", ChildGap = 10, AlignmentX = "center"}})(
						{
							Text({Text = "Pan"}),
							Slider({Mode = "horizontal", Value = 0.5, layout = {MinSize = Vec2(150, 20)}}),
						}
					),
					Column({layout = {Direction = "y", ChildGap = 10, AlignmentX = "center"}})(
						{
							Text({Text = "Pitch"}),
							Slider({Mode = "vertical", Value = 0.2, layout = {MinSize = Vec2(20, 150)}}),
						}
					),
				}
			)
		)
		return canvas
	end,
}
