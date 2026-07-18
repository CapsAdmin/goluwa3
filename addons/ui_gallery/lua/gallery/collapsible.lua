local Vec2 = import("goluwa/structs/vec2.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local Collapsible = import("goluwa/render2d/ui/widgets/collapsible.lua")
return {
	Name = "collapsible",
	Create = function()
		return Column{
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
				ChildGap = 10,
				AlignmentX = "stretch",
				Padding = "M",
			},
		}{
			Collapsible{
				Title = "Information",
				Collapsed = false,
			}(
				Text{
					Text = string.random_words(50),
					Wrap = true,
					layout = {
						GrowWidth = 1,
						Padding = "M",
					},
				}
			),
			Collapsible{
				Title = "Nested Elements",
				Collapsed = true,
			}(
				Column{
					layout = {
						Direction = "y",
						FitHeight = true,
						GrowWidth = 1,
						ChildGap = 5,
						Padding = "M",
					},
				}{
					Button{
						Text = "Button 1",
						layout = {
							GrowWidth = 1,
						},
					},
					Button{
						Text = "Button 2",
						layout = {
							GrowWidth = 1,
						},
					},
					Collapsible{
						Title = "Sub-Collapsible",
						Collapsed = true,
					}(
						Text{
							Wrap = true,
							WrapToParent = true,
							layout = {
								Padding = "M",
							},
							Text = string.random_words(5),
						}
					),
				}
			),
			Collapsible{
				Title = "Long Content",
				Collapsed = true,
			}(
				Text{
					Text = string.random_words(300),
					Wrap = true,
					layout = {
						GrowWidth = 1,
						Padding = "M",
					},
				}
			),
		}
	end,
}
