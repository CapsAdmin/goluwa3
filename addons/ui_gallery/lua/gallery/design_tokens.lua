local Vec2 = import("goluwa/structs/vec2.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local Swatch = react.Element(import("addons/ui_gallery/lua/gallery_swatch.lua"))
local palette = {
	"primary",
	"positive",
	"neutral",
	"negative",
	"text",
	"text_disabled",
	"surface",
	"surface_alt",
	"track",
	"border",
	"border_strong",
	"property_selection",
}
local sizes = {"XXXS", "XXS", "XS", "S", "M", "L", "XL", "XXL"}
local radii = {"XS", "S", "M", "L"}

return {
	Name = "design tokens",
	Section = "Foundations",
	Order = 2,
	View = react.Component(|| -> kit.Page{
		Title = "Design tokens",
		Description = "Spacing, radii and colors are named tokens resolved by the active theme. Widgets accept tokens wherever they accept numbers or colors, so a theme change restyles everything.",
	}{
		kit.Section{Title = "Palette", Description = "Color = \"token\" and ButtonColor = \"token\"."}{
			kit.Wrap(list.map(palette, |token| -> kit.Labeled(token, Swatch{Token = token})), {ChildGap = "M"}),
		},
		kit.Section{
			Title = "Spacing",
			Description = "Padding, ChildGap, Size and MinSize all take these tokens.",
		}{
			list.map(
				sizes,
				|token| -> do
					local size = theme.active:GetSize(token)

					return kit.Group{
						ui.Text{
							Text = token,
							Font = "body_strong S",
							IgnoreMouseInput = true,
							layout = {MinSize = Vec2(48, 0)},
						},
						Swatch{
							Token = "primary",
							Size = Vec2(size * 4, theme.active:GetSize("S")),
							Radius = "XS",
						},
						ui.Text{
							Text = size .. " px",
							Font = "body S",
							Color = "text_disabled",
							IgnoreMouseInput = true,
						},
					}
				end
			),
		},
		kit.Section{Title = "Corner radii"}{
			kit.Wrap(
				list.map(radii, |token| -> kit.Labeled(token, Swatch{Token = "surface_alt", Size = Vec2(72, 72), Radius = token})),
				{ChildGap = "M"}
			),
		},
	}),
}
