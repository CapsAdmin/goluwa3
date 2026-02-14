local Panel = require("ecs.panel")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local theme = runfile("lua/ui/theme.lua")
local Color = require("structs.color")
Panel.World:RemoveChildren()
local sidebarItems = {
	{text = "Copy", icon = "C"},
	{text = "Paste", icon = "P"},
	{text = "Delete", icon = "D"},
	{text = "Layer with a very long comment that should get wrapped", icon = "L"},
	{text = "Comment", icon = "#"},
}
local PURPLE = Color(0.3, 0.1, 0.5, 1)
local LIGHT_PURPLE = Color(0.5, 0.3, 0.7, 1)
local WHITE = Color(1, 1, 1, 1)
local outer = Panel.NewPanel(
	{
		Name = "OuterContainer",
		Color = PURPLE,
		layout = {
			Direction = "y",
			Padding = Rect() + theme.GetPadding("M"),
			ChildGap = theme.GetPadding("M"),
			FitWidth = true,
			MinSize = Vec2(50, 0),
			MaxSize = Vec2(250, 0),
			FitHeight = true,
		},
	}
)(
	{
		list.map(sidebarItems, function(item)
			return Panel.NewPanel(
				{
					Parent = outer,
					Color = LIGHT_PURPLE,
					layout = {
						Direction = "x",
						GrowWidth = 1,
						FitHeight = true,
						MinSize = Vec2(0, 0),
						Padding = Rect() + theme.GetPadding("M"),
						AlignmentY = "center",
						ChildGap = theme.GetPadding("M"),
					},
				}
			)(
				{
					Panel.NewText(
						{
							Parent = row,
							Text = item.text,
							Font = theme.GetFont("body"),
							FontSize = theme.GetFontSize("M"),
							Color = WHITE,
							Wrap = true,
							layout = {
								GrowWidth = 1,
								FitHeight = true,
							},
						}
					),
					Panel.NewText(
						{
							Parent = row,
							Text = item.icon,
							Font = theme.GetFont("heading"),
							FontSize = theme.GetFontSize("XXL"),
							Color = WHITE,
							AlignX = "center",
							AlignY = "center",
							layout = {
								MinSize = Vec2(30, 30),
								MaxSize = Vec2(30, 30),
							},
						}
					),
				}
			)
		end),
	}
)
outer:AddComponent("resizable")
outer:AddComponent("draggable")
outer.transform:SetPosition(Vec2(100, 100))
