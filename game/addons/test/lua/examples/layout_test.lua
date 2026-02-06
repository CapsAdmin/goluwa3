local Panel = require("ecs.panel")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local theme = runfile("lua/ui/theme.lua")
local Color = require("structs.color")
Panel.World:RemoveChildren()
local menuItems = {
	{text = "Copy", icon = "@"},
	{text = "Paste", icon = "$"},
	{text = "Delete", icon = "X"},
	{text = "Layer", icon = "/"},
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
			Padding = Rect(16, 16, 16, 16),
			ChildGap = 16,
			FitWidth = true,
			MinSize = Vec2(430, 0),
			MaxSize = Vec2(630, 0),
			FitHeight = true,
		},
	}
)

for _, item in ipairs(menuItems) do
	local row = Panel.NewPanel(
		{
			Parent = outer,
			Color = LIGHT_PURPLE,
			layout = {
				Direction = "x",
				GrowWidth = 1,
				FitHeight = true,
				MinSize = Vec2(0, 80),
				Padding = Rect(32, 16, 32, 16),
				AlignmentY = "center",
				ChildGap = 32,
			},
		}
	)
	local textContainer = Panel.NewPanel({Parent = row, layout = {
		GrowWidth = 1,
		FitHeight = true,
	}})
	Panel.NewText(
		{
			Parent = textContainer,
			Text = item.text,
			Font = theme.GetFont("body", 32),
			Color = WHITE,
			layout = {FitWidth = true, FitHeight = true},
		}
	)
	Panel.NewText(
		{
			Parent = row,
			Text = item.icon,
			Font = theme.GetFont("body", 24),
			Color = WHITE,
			layout = {
				MinSize = Vec2(60, 60),
				MaxSize = Vec2(60, 60),
				AlignmentX = "center",
				AlignmentY = "center",
			},
		}
	)
end

outer.transform:SetPosition(Vec2(100, 100))
