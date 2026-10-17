local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local WINDOW_SIZE = Vec2(380, 430)

return {
	Name = "color picker",
	Section = "Controls",
	Order = 6,
	View = react.Component(|| -> do
		local color, set_color = react.UseState(|| -> Color.FromBytes(54, 199, 255, 214))
		local initial = react.UseMemo(|| -> color, {})
		local window_position, set_window_position = react.UseState(nil)
		-- the picker windows start from the current color and keep their own after that
		local window_color = react.UseMemo(|| -> color, {window_position})
		local current = react.UseRef(color)
		current.current = color
		local bytes = color:Get255()
		local on_change = |value| -> set_color(value)

		-- drawn from a ref so the callback keeps its identity
		local draw_preview = react.UseCallback(|preview| -> do
			local size = preview.transform:GetSize()
			render2d.SetTexture(nil)

			for y = 0, math.ceil(size.y / 16) - 1 do
				for x = 0, math.ceil(size.x / 16) - 1 do
					local shade = (x + y) % 2 == 0 and 0.95 or 0.82
					render2d.SetColor(shade, shade, shade, 1)
					render2d.DrawRect(x * 16, y * 16, math.min(16, size.x - x * 16), math.min(16, size.y - y * 16))
				end
			end

			render2d.SetColor(current.current:Unpack())
			render2d.DrawRect(0, 0, size.x, size.y)
			render2d.SetColor(theme.active:GetColor("border"):Unpack())
			render2d.DrawRect(0, 0, size.x, 1)
			render2d.DrawRect(0, size.y - 1, size.x, 1)
			render2d.DrawRect(0, 0, 1, size.y)
			render2d.DrawRect(size.x - 1, 0, 1, size.y)
		end, {})

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
						ui.ColorPicker{
							Value = initial,
							OnChange = on_change,
							layout = {GrowWidth = 0, FitWidth = true},
						},
						ui.Column{layout = {ChildGap = "S", AlignmentX = "start", GrowWidth = 0, FitWidth = true}}{
							kit.Caption("Preview"),
							ui.Panel{
								transform = {Size = Vec2(160, 96)},
								layout = {MinSize = Vec2(160, 96), MaxSize = Vec2(160, 96)},
								visual = true,
								OnDraw = draw_preview,
							},
							ui.Text{
								Text = string.format(
									"RGBA %d, %d, %d, %d",
									math.floor(bytes.r + 0.5),
									math.floor(bytes.g + 0.5),
									math.floor(bytes.b + 0.5),
									math.floor(bytes.a + 0.5)
								),
								Color = "text_disabled",
								IgnoreMouseInput = true,
							},
							ui.Button{
								Text = "Open in window",
								Mode = "outline",
								OnClick = || -> set_window_position((Panel.World.transform:GetSize() - WINDOW_SIZE) / 2),
							},
						},
					},
					{AlignmentY = "start"}
				),
			},
			react.Portal{Target = Panel.World}{
				window_position && ui.Window{
					Key = "picker",
					Title = "COLOR PICKER",
					Size = WINDOW_SIZE,
					Position = window_position,
					OnClose = || -> set_window_position(nil),
				}{
					ui.ColorPicker{Value = window_color, OnChange = on_change, layout = {GrowWidth = 1}},
				},
			},
		}
	end),
}
