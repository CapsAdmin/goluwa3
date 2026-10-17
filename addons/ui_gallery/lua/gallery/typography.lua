local Vec2 = import("goluwa/structs/vec2.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local colors = {
	"text",
	"text_disabled",
	"primary",
	"positive",
	"neutral",
	"negative",
}
local COLUMN = {MinSize = Vec2(240, 0), MaxSize = Vec2(240, 0), FitHeight = true}

return {
	Name = "typography",
	Section = "Foundations",
	Order = 1,
	View = react.Component(|| -> kit.Page{
		Title = "Typography",
		Description = "Every text element picks a font style, a size and a palette token. Styles and sizes come from the active theme.",
	}{
		kit.Section{Title = "Font styles", Description = "Font = \"style Size\""}{
			list.map(
				theme.active:GetFontNamesList(),
				|name| -> kit.Labeled(
					name,
					ui.Text{Text = "Sphinx of black quartz, judge my vow", Font = name .. " L", IgnoreMouseInput = true}
				)
			),
		},
		kit.Section{Title = "Font sizes", Description = "XS through XXXL."}{
			list.map(
				theme.active:GetFontSizesList(),
				|name| -> kit.Group{
					ui.Text{
						Text = name,
						Font = "body_strong S",
						Color = "text_disabled",
						IgnoreMouseInput = true,
						layout = {MinSize = Vec2(40, 0)},
					},
					ui.Text{Text = "The quick brown fox", Font = "body " .. name, IgnoreMouseInput = true},
				}
			),
		},
		kit.Section{
			Title = "Palette tokens",
			Description = "Color = \"token\" resolves against the surface behind the text.",
		}{
			kit.Wrap(
				list.map(
					colors,
					|name| -> kit.Labeled(
						name,
						ui.Text{Text = "Aa Bb Cc", Font = "body_strong L", Color = name, IgnoreMouseInput = true}
					)
				),
				{ChildGap = "L"}
			),
		},
		kit.Section{
			Title = "Wrapping and alignment",
			Description = "Wrap = true flows text inside its parent. AlignX positions each line.",
		}{
			kit.Group(
				{
					kit.Labeled("AlignX = 0", ui.Frame{Padding = "S", layout = COLUMN}{kit.Paragraph(kit.Lorem, {AlignX = 0})}),
					kit.Labeled("AlignX = 0.5", ui.Frame{Padding = "S", layout = COLUMN}{kit.Paragraph(kit.Lorem, {AlignX = 0.5})}),
					kit.Labeled("AlignX = 1", ui.Frame{Padding = "S", layout = COLUMN}{kit.Paragraph(kit.Lorem, {AlignX = 1})}),
					kit.Labeled("Justify = true", ui.Frame{Padding = "S", layout = COLUMN}{kit.Paragraph(kit.Lorem, {Justify = true})}),
				},
				{AlignmentY = "start", WrapChildren = true}
			),
		},
		kit.Section{
			Title = "Eliding",
			Description = "Elide = true truncates with an ellipsis when the text does not fit.",
		}{
			ui.Frame{Padding = "S", layout = {MinSize = Vec2(200, 0), MaxSize = Vec2(200, 0), FitHeight = true}}{
				ui.Text{
					Text = "A very long name that cannot possibly fit in this box",
					Elide = true,
					IgnoreMouseInput = true,
					layout = {GrowWidth = 1},
				},
			},
			ui.Frame{Padding = "S", layout = {GrowWidth = 1, FitHeight = true}}{
				ui.Text{
					Text = kit.Lorem .. " " .. kit.Lorem .. " " .. kit.Lorem .. " " .. kit.Lorem,
					Elide = true,
					IgnoreMouseInput = true,
					layout = {GrowWidth = 1},
				},
			},
		},
	}),
}
