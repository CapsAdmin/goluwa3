local Vec2 = import("goluwa/structs/vec2.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local Frame = import("goluwa/render2d/ui/elements/frame.lua")
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
return {
	Name = "typography",
	Section = "Foundations",
	Order = 1,
	Create = function()
		local styles = {}

		for _, name in ipairs(theme.active:GetFontNamesList()) do
			styles[#styles + 1] = kit.Labeled(
				name,
				Text{
					Text = "Sphinx of black quartz, judge my vow",
					Font = name .. " L",
					IgnoreMouseInput = true,
				}
			)
		end

		local sizes = {}

		for _, name in ipairs(theme.active:GetFontSizesList()) do
			sizes[#sizes + 1] = kit.Group{
				Text{
					Text = name,
					Font = "body_strong S",
					Color = "text_disabled",
					IgnoreMouseInput = true,
					layout = {MinSize = Vec2(40, 0)},
				},
				Text{Text = "The quick brown fox", Font = "body " .. name, IgnoreMouseInput = true},
			}
		end

		local tokens = {}

		for _, name in ipairs(colors) do
			tokens[#tokens + 1] = kit.Labeled(
				name,
				Text{
					Text = "Aa Bb Cc",
					Font = "body_strong L",
					Color = name,
					IgnoreMouseInput = true,
				}
			)
		end

		return kit.Page{
			Title = "Typography",
			Description = "Every text element picks a font style, a size and a palette token. Styles and sizes come from the active theme.",
		}{
			kit.Section{Title = "Font styles", Description = "Font = \"style Size\""}(styles),
			kit.Section{Title = "Font sizes", Description = "XS through XXXL."}(sizes),
			kit.Section{
				Title = "Palette tokens",
				Description = "Color = \"token\" resolves against the surface behind the text.",
			}{
				kit.Wrap(tokens, {ChildGap = "L"}),
			},
			kit.Section{
				Title = "Wrapping and alignment",
				Description = "Wrap = true flows text inside its parent. AlignX positions each line.",
			}{
				kit.Group(
					{
						kit.Labeled(
							"AlignX = 0",
							Frame{
								Padding = "S",
								layout = {MinSize = Vec2(240, 0), MaxSize = Vec2(240, 0), FitHeight = true},
							}{kit.Paragraph(kit.Lorem, {AlignX = 0})}
						),
						kit.Labeled(
							"AlignX = 0.5",
							Frame{
								Padding = "S",
								layout = {MinSize = Vec2(240, 0), MaxSize = Vec2(240, 0), FitHeight = true},
							}{kit.Paragraph(kit.Lorem, {AlignX = 0.5})}
						),
						kit.Labeled(
							"AlignX = 1",
							Frame{
								Padding = "S",
								layout = {MinSize = Vec2(240, 0), MaxSize = Vec2(240, 0), FitHeight = true},
							}{kit.Paragraph(kit.Lorem, {AlignX = 1})}
						),
						kit.Labeled(
							"Justify = true",
							Frame{
								Padding = "S",
								layout = {MinSize = Vec2(240, 0), MaxSize = Vec2(240, 0), FitHeight = true},
							}{kit.Paragraph(kit.Lorem, {Justify = true})}
						),
					},
					{AlignmentY = "start", WrapChildren = true}
				),
			},
			kit.Section{
				Title = "Eliding",
				Description = "Elide = true truncates with an ellipsis when the text does not fit.",
			}{
				Frame{
					Padding = "S",
					layout = {MinSize = Vec2(200, 0), MaxSize = Vec2(200, 0), FitHeight = true},
				}{
					Text{
						Text = "A very long name that cannot possibly fit in this box",
						Elide = true,
						IgnoreMouseInput = true,
						layout = {GrowWidth = 1},
					},
				},
				Frame{Padding = "S", layout = {GrowWidth = 1, FitHeight = true}}{
					Text{
						Text = kit.Lorem .. " " .. kit.Lorem .. " " .. kit.Lorem .. " " .. kit.Lorem,
						Elide = true,
						IgnoreMouseInput = true,
						layout = {GrowWidth = 1},
					},
				},
			},
		}
	end,
}
