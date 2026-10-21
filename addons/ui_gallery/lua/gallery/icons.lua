local Vec2 = import("goluwa/structs/vec2.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local icon_set = import("goluwa/render2d/ui/themes/icons.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local WEIGHT_ICONS = {"check", "search", "cube", "folder_open", "settings", "light", "world", "move"}
local WEIGHTS = {1, 1.75, 2.75}
local CAPS = {"butt", "round", "square"}
local JOINS = {"miter", "round", "bevel"}
local IconTile = react.Memo(
	react.Component(
		|props|->ui.Frame{
			Padding = "S",
			layout = {FitWidth = true, FitHeight = true, GrowWidth = 0, MinSize = Vec2(104, 0)},
		}{
			ui.Column{
				layout = {ChildGap = "XS", AlignmentX = "center", GrowWidth = 0, FitWidth = true},
			}{
				ui.Icon{Icon = props.Name, Size = props.Size},
				ui.Text{Text = props.Name, Font = "body XS", IgnoreMouseInput = true},
			},
		}
	)
)

local function make_svg(key, name, props)
	props.Key = key
	props.Source = theme.active:GetIconSource(name)
	props.Color = "text"
	props.Size = Vec2(56, 56)
	return ui.SVG(props)
end

return {
	Name = "icons",
	Section = "Graphics",
	Order = 0,
	View = react.Component(
		||-> do
			local size, set_size = react.UseState(40)
			local style = theme.active:GetIconStyle()
			local icon_size = Vec2(size, size)
			local listed = {}
			local sections = {
				kit.Section{
					Title = "Style",
					Description = "Icons are stroked line drawings. The active theme decides how they are stroked (IconStyle), switch the theme to compare.",
				}{
					kit.Paragraph(
						(
							"%s: StrokeWidth %s, LineCap %s, LineJoin %s"
						):format(
							theme.active:GetName(),
							style.StrokeWidth,
							style.LineCap,
							style.LineJoin
						)
					),
					kit.Group{
						ui.Text{Text = "Icon size: " .. size, IgnoreMouseInput = true},
						ui.Slider{
							Min = 16,
							Max = 96,
							Value = 40,
							OnChange = |value|->set_size(math.floor(value + 0.5)),
							layout = {GrowWidth = 1},
						},
					},
				},
			}

			for _, category in ipairs(icon_set.Categories) do
				for _, name in ipairs(category.Icons) do
					listed[name] = true
				end

				sections[#sections + 1] = kit.Section{Title = category.Name}{
					kit.Wrap(
						list.map(category.Icons, |name|->IconTile{Key = name, Name = name, Size = icon_size}),
						{AlignmentY = "start"}
					),
				}
			end

			local theme_icons = list.filter(theme.active:GetIconNames(), |name|->not listed[name])

			if theme_icons[1] then
				sections[#sections + 1] = kit.Section{Title = "Theme", Description = "Icons only the active theme defines."}{
					kit.Wrap(
						list.map(theme_icons, |name|->IconTile{Key = name, Name = name, Size = icon_size}),
						{AlignmentY = "start"}
					),
				}
			end

			sections[#sections + 1] = kit.Section{
				Title = "Weights",
				Description = "The same icons at the stroke widths of jrpg, the base theme and playful. IconStyle.StrokeWidth is in the 24 unit grid of the icons.",
			}{
				list.map(
					WEIGHTS,
					|width|->kit.Labeled(
						"StrokeWidth = " .. width,
						kit.Group(list.map(WEIGHT_ICONS, |name|->make_svg(name, name, {StrokeWidth = width})))
					)
				),
			}
			local cells = {}

			for _, cap in ipairs(CAPS) do
				for _, join in ipairs(JOINS) do
					cells[#cells + 1] = kit.Labeled(
						cap .. " / " .. join,
						make_svg(cap .. join, "arrow_right", {StrokeWidth = 3, LineCap = cap, LineJoin = join})
					)
				end
			end

			sections[#sections + 1] = kit.Section{
				Title = "Caps and joins",
				Description = "IconStyle.LineCap = butt | round | square, IconStyle.LineJoin = miter | round | bevel.",
			}{kit.Wrap(cells, {AlignmentY = "start"})}
			return kit.Page{
				Title = "Icons",
				Description = "Every icon the base theme defines, drawn with Icon{Icon = name}. Themes can override single icons and set the IconStyle that strokes all of them.",
			}{sections}
		end
	),
}
