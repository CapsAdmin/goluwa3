local Vec2 = import("goluwa/structs/vec2.lua")
local Frame = import("goluwa/render2d/ui/elements/frame.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Slider = import("goluwa/render2d/ui/elements/slider.lua")
local Icon = import("goluwa/render2d/ui/elements/icon.lua")
local SVG = import("goluwa/render2d/ui/elements/svg.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local icon_set = import("goluwa/render2d/ui/themes/icons.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local WEIGHT_ICONS = {"check", "search", "cube", "folder_open", "settings", "light", "world", "move"}
local WEIGHTS = {1, 1.75, 2.75}
local CAPS = {"butt", "round", "square"}
local JOINS = {"miter", "round", "bevel"}

local function on_size_change(value, slider)
	local page = slider.Page
	local size = math.floor(value + 0.5)
	page.label.text:SetText("Icon size: " .. size)

	for _, icon in ipairs(page.icons) do
		icon.transform:SetSize(Vec2(size, size))
	end
end

local function make_tile(page, name)
	local icon = Icon{Icon = name, Size = Vec2(40, 40)}
	page.icons[#page.icons + 1] = icon
	return Frame{
		Padding = "S",
		layout = {FitWidth = true, FitHeight = true, GrowWidth = 0, MinSize = Vec2(104, 0)},
	}{
		Column{
			layout = {ChildGap = "XS", AlignmentX = "center", GrowWidth = 0, FitWidth = true},
		}{
			icon,
			Text{Text = name, Font = "body XS", IgnoreMouseInput = true},
		},
	}
end

local function make_svg(name, props)
	props.Source = theme.active:GetIconSource(name)
	props.Color = "text"
	props.Size = Vec2(56, 56)
	return SVG(props)
end

return {
	Name = "icons",
	Section = "Graphics",
	Order = 0,
	Create = function()
		local page = {icons = {}}
		local style = theme.active:GetIconStyle()
		page.label = Text{Text = "Icon size: 40", IgnoreMouseInput = true}
		local sections = {
			kit.Section{
				Title = "Style",
				Description = "Icons are stroked line drawings. The active theme decides how they are stroked (IconStyle), switch the theme to compare.",
			}{
				kit.Paragraph(
					("%s: StrokeWidth %s, LineCap %s, LineJoin %s"):format(
						theme.active:GetName(),
						style.StrokeWidth,
						style.LineCap,
						style.LineJoin
					)
				),
				kit.Group{
					page.label,
					Slider{
						Page = page,
						Min = 16,
						Max = 96,
						Value = 40,
						OnChange = on_size_change,
						layout = {GrowWidth = 1},
					},
				},
			},
		}
		local listed = {}

		for _, category in ipairs(icon_set.Categories) do
			local tiles = {}

			for _, name in ipairs(category.Icons) do
				listed[name] = true
				tiles[#tiles + 1] = make_tile(page, name)
			end

			sections[#sections + 1] = kit.Section{Title = category.Name}{kit.Wrap(tiles, {AlignmentY = "start"})}
		end

		local theme_tiles = {}

		for _, name in ipairs(theme.active:GetIconNames()) do
			if not listed[name] then theme_tiles[#theme_tiles + 1] = make_tile(page, name) end
		end

		if theme_tiles[1] then
			sections[#sections + 1] = kit.Section{
				Title = "Theme",
				Description = "Icons only the active theme defines.",
			}{kit.Wrap(theme_tiles, {AlignmentY = "start"})}
		end

		local weight_rows = {}

		for _, width in ipairs(WEIGHTS) do
			local svgs = {}

			for _, name in ipairs(WEIGHT_ICONS) do
				svgs[#svgs + 1] = make_svg(name, {StrokeWidth = width})
			end

			weight_rows[#weight_rows + 1] = kit.Labeled("StrokeWidth = " .. width, kit.Group(svgs))
		end

		sections[#sections + 1] = kit.Section{
			Title = "Weights",
			Description = "The same icons at the stroke widths of jrpg, the base theme and playful. IconStyle.StrokeWidth is in the 24 unit grid of the icons.",
		}(weight_rows)
		local cells = {}

		for _, cap in ipairs(CAPS) do
			for _, join in ipairs(JOINS) do
				cells[#cells + 1] = kit.Labeled(
					cap .. " / " .. join,
					make_svg("arrow_right", {StrokeWidth = 3, LineCap = cap, LineJoin = join})
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
		}(sections)
	end,
}
