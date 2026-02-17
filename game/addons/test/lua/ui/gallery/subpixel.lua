local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Text = require("ui.elements.text")
local Slider = require("ui.elements.slider")
local Dropdown = require("ui.elements.dropdown")
local Row = require("ui.elements.row")
local Column = require("ui.elements.column")
local fonts = require("render2d.fonts")
local render2d = require("render2d.render2d")
local Panel = require("ecs.panel")
return {
	Name = "subpixel",
	Create = function()
		local canvas = Column(
			{
				layout = {
					Direction = "y",
					FitHeight = true,
					GrowWidth = 1,
					ChildGap = 20,
					Padding = Rect(20, 20, 20, 20),
					AlignmentX = "stretch",
				},
			}
		)
		local state = {
			selected_mode = "none",
			selected_amount = 0.333,
		}
		local fontPath = fonts.GetDefaultSystemFontPath()
		local demo_fonts = {}
		local sizes = {7, 8, 9, 10, 11, 12, 13, 14, 15, 18, 24}

		for _, size in ipairs(sizes) do
			demo_fonts[size] = fonts.New({Path = fontPath, Size = size})
		end

		local label_ent = NULL
		return canvas(
			{
				-- Settings Row
				Row(
					{
						layout = {
							Direction = "x",
							ChildGap = 20,
							AlignmentY = "center",
							FitHeight = true,
							GrowWidth = 1,
						},
					}
				)(
					{
						Column({layout = {Direction = "y", ChildGap = 5, FitWidth = true}})(
							{
								Text({Text = "Mode:"}),
								Dropdown(
									{
										Value = state.selected_mode,
										Options = {"none", "rgb", "bgr", "vrgb", "vbgr", "rwgb"},
										OnSelect = function(val)
											state.selected_mode = val

											if val == "rwgb" then
												state.selected_amount = 0.25
											else
												state.selected_amount = 0.333
											end
										end,
										layout = {Size = Vec2(120, 30)},
									}
								),
							}
						),
						Column({layout = {Direction = "y", ChildGap = 5, GrowWidth = 1}})(
							{
								Text({Text = "Intensity (Amount):"}),
								Row({layout = {Direction = "x", ChildGap = 10, AlignmentY = "center"}})(
									{
										Slider(
											{
												Value = state.selected_amount * 100,
												Min = 0,
												Max = 100,
												OnChange = function(val, s)
													state.selected_amount = val / 100

													if label_ent:IsValid() then
														label_ent.text:SetText(string.format("%.3f", state.selected_amount))
													end
												end,
												layout = {GrowWidth = 1, FitHeight = true},
											}
										),
										(
											function()
												local p = Text(
													{
														Text = string.format("%.3f", state.selected_amount),
														layout = {Size = Vec2(40, 20)},
													}
												)
												label_ent = p
												return p
											end
										)(),
									}
								),
							}
						),
					}
				),
				-- Demo Area
				Panel.New(
					{
						transform = true,
						rect = true,
						layout = {
							GrowWidth = 1,
							GrowHeight = 1,
							MinSize = Vec2(100, 400),
						},
						OnDraw = function(self)
							local transform = self.transform
							local s = transform.Size + transform.DrawSizeOffset
							render2d.SetColor(1, 1, 1, 1)
							render2d.SetTexture(nil)
							render2d.DrawRect(0, 0, s.x, s.y)
							render2d.PushSubpixelMode(state.selected_mode)
							render2d.PushSubpixelAmount(state.selected_amount)
							local y = 20
							local x = 20
							-- 1. Black on White
							render2d.PushBlendMode("multiply")
							render2d.SetColor(0, 0, 0, 1)

							for _, size in ipairs(sizes) do
								demo_fonts[size]:DrawText("The quick brown fox jumps over the lazy dog (" .. size .. "px)", x, y)
								y = y + size + 4
							end

							render2d.PopBlendMode()
							y = y + 20
							-- 2. White on Black
							render2d.SetColor(0.1, 0.1, 0.1, 1)
							render2d.DrawRect(x - 5, y - 5, s.x - 30, 40)
							render2d.PushBlendMode("additive")
							render2d.SetColor(1, 1, 1, 1)
							demo_fonts[24]:DrawText("Large Subpixel Text on Dark", x, y)
							render2d.PopBlendMode()
							render2d.PopSubpixelAmount()
							render2d.PopSubpixelMode()
						end,
					}
				),
			}
		)
	end,
}
