local Text = require("ui.elements.text")
local Panel = require("ecs.panel")
local ScrollablePanel = require("ui.elements.scrollable_panel")
local Column = require("ui.elements.column")
local Button = require("ui.elements.button")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local system = require("system")
return {
	Name = "Overflow Loop Demo",
	Create = function()
		return Column(
			{
				layout = {
					Direction = "y",
					ChildGap = 10,
					AlignmentX = "start",
					AlignmentY = "start",
				},
			}
		)(
			{
				ScrollablePanel(
					{
						Color = Color(0, 0, 0, 0.5),
						layout = {
							MinSize = Vec2(100, 100),
							MaxSize = Vec2(100, 100),
						},
					}
				)(
					Column(
						{
							layout = {
								Direction = "y",
								ChildGap = 5,
								AlignmentX = "start",
								FitHeight = true,
							},
						}
					)(
						{
							Button({Text = "Clickable Item", Padding = "XS"}),
							Text({Text = "Scrollable Content Demo - 100 Items Below"}),
							(
								function()
									local t = {}

									for i = 1, 100 do
										t[i] = Text({Text = "Scrolling Item #" .. i})
									end

									return t
								end
							)(),
							Text({Text = "End of List"}),
						}
					)
				),
				ScrollablePanel(
					{
						Color = Color(0, 0, 0, 0.5),
						ScrollX = true,
						layout = {
							MinSize = Vec2(100, 100),
							MaxSize = Vec2(100, 100),
						},
					}
				)(
					Panel.New(
						{
							Name = "AnimatedPanel",
							transform = true,
							layout = {
								AlignmentX = "center",
								AlignmentY = "center",
							},
							gui_element = {
								Color = Color(1, 0.5, 0, 0.5),
							},
							Ref = function(self)
								self:AddGlobalEvent("Update")
							end,
							OnUpdate = function(self, dt)
								local t = system.GetElapsedTime()
								local w = 10 + (math.sin(t * 2) * 0.5 + 0.5) * 150
								local h = 10 + (math.cos(t * 2) * 0.5 + 0.5) * 150
								self.transform:SetSize(Vec2(w, h))
							end,
						}
					)(
						Text(
							{
								Text = "I am overflowable!",
								text = {
									AlignX = "center",
									AlignY = "center",
								},
							}
						)
					)
				),
				Text({Text = "Horizontal Scrolling Demo (Shift + Scroll or Drag)"}),
				ScrollablePanel(
					{
						Color = Color(0, 0, 0, 0.5),
						ScrollX = true,
						ScrollY = false,
						layout = {
							MinSize = Vec2(200, 50),
							MaxSize = Vec2(200, 50),
						},
					}
				)(
					Column(
						{
							layout = {
								Direction = "x",
								ChildGap = 10,
								AlignmentY = "center",
								FitWidth = true,
							},
						}
					)(
						(
							function()
								local t = {}

								for i = 1, 20 do
									t[i] = Button({Text = "Item " .. i, Padding = "XS"})
								end

								return t
							end
						)()
					)
				),
			}
		)
	end,
}
