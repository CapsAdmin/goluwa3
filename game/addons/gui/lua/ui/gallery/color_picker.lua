local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/ecs/panel.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Button = import("../widgets/button.lua")
local ColorPicker = import("../widgets/color_picker.lua")
local Column = import("../elements/column.lua")
local Row = import("../elements/row.lua")
local Text = import("../elements/text.lua")
local Window = import("../widgets/window.lua")
local theme = import("../theme.lua")

local function format_summary(color)
	local rgba = color:Get255()
	return string.format(
		"RGBA  %d, %d, %d, %d  |  %s",
		math.floor(rgba.r + 0.5),
		math.floor(rgba.g + 0.5),
		math.floor(rgba.b + 0.5),
		math.floor(rgba.a + 0.5),
		string.format(
			"#%02X%02X%02X%02X",
			math.floor(rgba.r + 0.5),
			math.floor(rgba.g + 0.5),
			math.floor(rgba.b + 0.5),
			math.floor(rgba.a + 0.5)
		)
	)
end

return {
	Name = "color picker",
	Create = function()
		local state = {
			color = Color.FromBytes(54, 199, 255, 214),
		}
		local summary
		local preview

		local function update_preview()
			if preview and preview:IsValid() and preview.gui_element then
				preview.preview_color = state.color
			end

			if summary and summary:IsValid() and summary.text then
				summary.text:SetText(format_summary(state.color))
			end
		end

		local function open_picker_window()
			local world_size = Panel.World.transform:GetSize()
			local size = Vec2(380, 430)
			Panel.World:Ensure(
				Window{
					Key = "GalleryColorPickerWindow",
					Title = "COLOR PICKER",
					Size = size,
					Position = (world_size - size) / 2,
					OnClose = function(self)
						self:Remove()
					end,
				}{
					ColorPicker{
						Value = state.color,
						OnChange = function(color)
							state.color = color
							update_preview()
						end,
						layout = {
							GrowWidth = 1,
						},
					},
				}
			)
		end

		local page = Column{
			layout = {
				Direction = "y",
				GrowWidth = 1,
				FitHeight = true,
				ChildGap = 16,
				Padding = Rect(
					theme.GetPadding("M"),
					theme.GetPadding("M"),
					theme.GetPadding("M"),
					theme.GetPadding("M")
				),
			},
		}{
			Text{
				Text = "Generated HSV/alpha textures, byte-space RGBA inputs, and a property-style popup window.",
				Color = "text_disabled",
				layout = {
					GrowWidth = 1,
				},
			},
			Row{
				layout = {
					ChildGap = 20,
					AlignmentY = "start",
					FitHeight = true,
				},
			}{
				ColorPicker{
					Value = state.color,
					OnChange = function(color)
						state.color = color
						update_preview()
					end,
				},
				Column{
					layout = {
						FitHeight = true,
						ChildGap = 10,
						MinSize = Vec2(200, 0),
					},
				}{
					Text{
						Text = "Preview",
						FontName = "heading",
					},
					Panel.New{
						Ref = function(self)
							preview = self
							update_preview()
						end,
						transform = {
							Size = Vec2(160, 96),
						},
						layout = {
							MinSize = Vec2(160, 96),
							MaxSize = Vec2(160, 96),
						},
						gui_element = {
							OnDraw = function(self)
								local size = self.Owner.transform:GetSize()
								local preview_color = self.Owner.preview_color or state.color
								render2d.SetTexture(nil)
								render2d.SetColor(1, 1, 1, 1)

								for y = 0, 5 do
									for x = 0, 9 do
										local checker = ((x + y) % 2) == 0 and 0.95 or 0.82
										render2d.SetColor(checker, checker, checker, 1)
										render2d.DrawRect(x * 16, y * 16, 16, 16)
									end
								end

								render2d.SetColor(preview_color:Unpack())
								render2d.DrawRect(0, 0, size.x, size.y)
								render2d.SetColor(theme.GetColor("border"):Unpack())
								render2d.DrawRect(0, 0, size.x, 1)
								render2d.DrawRect(0, size.y - 1, size.x, 1)
								render2d.DrawRect(0, 0, 1, size.y)
								render2d.DrawRect(size.x - 1, 0, 1, size.y)
							end,
						},
					},
					Text{
						Ref = function(self)
							summary = self
							update_preview()
						end,
						Text = "",
						layout = {
							GrowWidth = 1,
						},
					},
					Button{
						Text = "Open In Window",
						Mode = "outline",
						OnClick = open_picker_window,
					},
				},
			},
		}
		return page
	end,
}
