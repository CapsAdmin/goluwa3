local Text = import("../elements/text.lua")
local Panel = import("goluwa/ecs/panel.lua")
local ScrollablePanel = import("../elements/scrollable_panel.lua")
local Column = import("../elements/column.lua")
local Button = import("../elements/button.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local system = import("goluwa/system.lua")
return {
	Name = "scrolling",
	Create = function()
		local vertical_scroll
		local horizontal_scroll
		local vertical_items = {}
		local horizontal_items = {}

		local function build_vertical_items()
			local t = {
				Button{Text = "Clickable Item", Padding = "XS"},
				Text({Text = "Scrollable Content Demo - 100 Items Below"}),
			}

			for i = 1, 100 do
				t[#t + 1] = Text{
					Ref = function(self)
						vertical_items[i] = self
					end,
					Text = "Scrolling Item #" .. i,
				}
			end

			t[#t + 1] = Text{
				Ref = function(self)
					vertical_items[101] = self
				end,
				Text = "End of List",
			}
			return t
		end

		local function build_horizontal_items()
			local t = {}

			for i = 1, 20 do
				t[#t + 1] = Button{
					Ref = function(self)
						horizontal_items[i] = self
					end,
					Text = "Item " .. i,
					Padding = "XS",
				}
			end

			return t
		end

		return Column{
			layout = {
				Direction = "y",
				ChildGap = 10,
				AlignmentX = "start",
				AlignmentY = "start",
			},
		}{
			Text({Text = "Vertical Scroll Debug"}),
			Column{
				layout = {
					Direction = "x",
					ChildGap = 8,
					FitWidth = true,
				},
			}{
				Button{
					Text = "Top",
					OnClick = function()
						if vertical_scroll and vertical_scroll:IsValid() then
							vertical_scroll:ScrollChildIntoView(vertical_items[1], 8)
						end
					end,
				},
				Button{
					Text = "Item 25",
					Mode = "outline",
					OnClick = function()
						if vertical_scroll and vertical_scroll:IsValid() then
							vertical_scroll:ScrollChildIntoView(vertical_items[25], 8)
						end
					end,
				},
				Button{
					Text = "Item 50",
					Mode = "outline",
					OnClick = function()
						if vertical_scroll and vertical_scroll:IsValid() then
							vertical_scroll:ScrollChildIntoView(vertical_items[50], 8)
						end
					end,
				},
				Button{
					Text = "Bottom",
					Mode = "outline",
					OnClick = function()
						if vertical_scroll and vertical_scroll:IsValid() then
							vertical_scroll:ScrollChildIntoView(vertical_items[101], 8)
						end
					end,
				},
			},
			ScrollablePanel{
				Ref = function(self)
					vertical_scroll = self
				end,
				Color = Color(0, 0, 0, 0.5),
				layout = {
					MinSize = Vec2(100, 100),
					MaxSize = Vec2(100, 100),
				},
			}(
				Column{
					layout = {
						Direction = "y",
						ChildGap = 5,
						AlignmentX = "start",
						FitHeight = true,
					},
				}(build_vertical_items())
			),
			ScrollablePanel{
				Color = Color(0, 0, 0, 0.5),
				ScrollX = true,
				layout = {
					MinSize = Vec2(100, 100),
					MaxSize = Vec2(100, 100),
				},
			}(
				Panel.New{
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
				}(
					Text{
						Text = "I am overflowable!",
						text = {
							AlignX = "center",
							AlignY = "center",
						},
					}
				)
			),
			Text({Text = "Horizontal Scrolling Demo (Shift + Scroll or Drag)"}),
			Column{
				layout = {
					Direction = "x",
					ChildGap = 8,
					FitWidth = true,
				},
			}{
				Button{
					Text = "Start",
					OnClick = function()
						if horizontal_scroll and horizontal_scroll:IsValid() then
							horizontal_scroll:ScrollChildIntoView(horizontal_items[1], 8)
						end
					end,
				},
				Button{
					Text = "Item 10",
					Mode = "outline",
					OnClick = function()
						if horizontal_scroll and horizontal_scroll:IsValid() then
							horizontal_scroll:ScrollChildIntoView(horizontal_items[10], 8)
						end
					end,
				},
				Button{
					Text = "End",
					Mode = "outline",
					OnClick = function()
						if horizontal_scroll and horizontal_scroll:IsValid() then
							horizontal_scroll:ScrollChildIntoView(horizontal_items[20], 8)
						end
					end,
				},
			},
			ScrollablePanel{
				Ref = function(self)
					horizontal_scroll = self
				end,
				Color = Color(0, 0, 0, 0.5),
				ScrollX = true,
				ScrollY = false,
				layout = {
					MinSize = Vec2(200, 50),
					MaxSize = Vec2(200, 50),
				},
			}(
				Column{
					layout = {
						Direction = "x",
						ChildGap = 10,
						AlignmentY = "center",
						FitWidth = true,
					},
				}(build_horizontal_items())
			),
		}
	end,
}
