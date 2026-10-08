local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local ColorPicker = import("goluwa/render2d/ui/widgets/color_picker.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")

local function on_color_change(color, old_color, picker)
	local page = picker.Page
	page.color = color
	local bytes = color:Get255()
	page.summary.text:SetText(
		string.format(
			"RGBA %d, %d, %d, %d",
			math.floor(bytes.r + 0.5),
			math.floor(bytes.g + 0.5),
			math.floor(bytes.b + 0.5),
			math.floor(bytes.a + 0.5)
		)
	)
end

local function draw_preview(preview)
	local size = preview.transform:GetSize()
	render2d.SetTexture(nil)

	for y = 0, math.ceil(size.y / 16) - 1 do
		for x = 0, math.ceil(size.x / 16) - 1 do
			local shade = (x + y) % 2 == 0 and 0.95 or 0.82
			render2d.SetColor(shade, shade, shade, 1)
			render2d.DrawRect(x * 16, y * 16, math.min(16, size.x - x * 16), math.min(16, size.y - y * 16))
		end
	end

	render2d.SetColor(preview.Page.color:Unpack())
	render2d.DrawRect(0, 0, size.x, size.y)
	render2d.SetColor(theme.active:GetColor("border"):Unpack())
	render2d.DrawRect(0, 0, size.x, 1)
	render2d.DrawRect(0, size.y - 1, size.x, 1)
	render2d.DrawRect(0, 0, 1, size.y)
	render2d.DrawRect(size.x - 1, 0, 1, size.y)
end

local function open_window(button)
	local page = button.Page
	local size = Vec2(380, 430)
	Panel.World:Ensure(
		Window{
			Key = "GalleryColorPickerWindow",
			Title = "COLOR PICKER",
			Size = size,
			Position = (Panel.World.transform:GetSize() - size) / 2,
		}{
			ColorPicker{
				Page = page,
				Value = page.color,
				OnChange = on_color_change,
				layout = {GrowWidth = 1},
			},
		}
	)
end

return {
	Name = "color picker",
	Section = "Controls",
	Order = 6,
	Create = function()
		local page = {color = Color.FromBytes(54, 199, 255, 214)}
		page.summary = Text{
			Text = "RGBA 54, 199, 255, 214",
			Color = "text_disabled",
			IgnoreMouseInput = true,
		}
		local preview = Panel.New{
			Page = page,
			transform = {Size = Vec2(160, 96)},
			layout = {
				MinSize = Vec2(160, 96),
				MaxSize = Vec2(160, 96),
			},
			visual = true,
			OnDraw = draw_preview,
		}
		return kit.Page{
			Title = "Color picker",
			Description = "HSV and alpha surfaces rendered from generated textures, byte-space RGBA fields, a hex field and clipboard-friendly values.",
		}{
			kit.Section{
				Title = "Inline",
				Description = "OnChange(color, old_color, picker). SetValue(color, notify) updates it from code.",
			}{
				kit.Group(
					{
						ColorPicker{
							Page = page,
							Value = page.color,
							OnChange = on_color_change,
							layout = {GrowWidth = 0, FitWidth = true},
						},
						Column{layout = {ChildGap = "S", AlignmentX = "start", GrowWidth = 0, FitWidth = true}}{
							kit.Caption("Preview"),
							preview,
							page.summary,
							Button{Page = page, Text = "Open in window", Mode = "outline", OnClick = open_window},
						},
					},
					{AlignmentY = "start"}
				),
			},
		}
	end,
}
