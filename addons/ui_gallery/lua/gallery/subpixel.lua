local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Dropdown = import("goluwa/render2d/ui/widgets/dropdown.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local SVG = import("goluwa/render2d/svg.lua")
local pvars = import("goluwa/cli/pvars.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local layout_labels = {
	off = "Off (grayscale)",
	rgb = "RGB stripe",
	bgr = "BGR stripe",
	vrgb = "Vertical RGB (rotated display)",
	vbgr = "Vertical BGR (rotated display)",
	rwbg = "LG WOLED RWBG (C1, C2, C3, G3)",
	bwrg = "LG WOLED BWRG (G5)",
}
local backgrounds = {
	{
		background = Color(1, 1, 1, 1),
		foreground = Color(0.1, 0.1, 0.1, 1),
		name = "dark on light",
	},
	{
		background = Color(0.1, 0.1, 0.1, 1),
		foreground = Color(0.9, 0.9, 0.9, 1),
		name = "light on dark",
	},
	{
		background = Color(0.9, 0.9, 0.2, 1),
		foreground = Color(0.1, 0.1, 0.6, 1),
		name = "colored",
	},
}
local text_sizes = {5, 6, 7, 8, 9, 10}
local PATTERN_SIZE = 32
local patterns = {
	{name = "vertical lines 1px", kind = "vertical", cell = 1},
	{name = "vertical lines 2px", kind = "vertical", cell = 2},
	{name = "horizontal lines 1px", kind = "horizontal", cell = 1},
	{name = "horizontal lines 2px", kind = "horizontal", cell = 2},
	{name = "checkerboard 1px", kind = "checkerboard", cell = 1},
	{name = "checkerboard 2px", kind = "checkerboard", cell = 2},
}

local function build_pattern_source(kind, cell)
	local parts = {}

	if kind == "vertical" then
		for x = 0, PATTERN_SIZE - 1, cell * 2 do
			parts[#parts + 1] = string.format("M%d 0h%dv%dh-%dz", x, cell, PATTERN_SIZE, cell)
		end
	elseif kind == "horizontal" then
		for y = 0, PATTERN_SIZE - 1, cell * 2 do
			parts[#parts + 1] = string.format("M0 %dh%dv%dh-%dz", y, PATTERN_SIZE, cell, PATTERN_SIZE)
		end
	else
		for j = 0, PATTERN_SIZE / cell - 1 do
			for i = 0, PATTERN_SIZE / cell - 1 do
				if (i + j) % 2 == 0 then
					parts[#parts + 1] = string.format("M%d %dh%dv%dh-%dz", i * cell, j * cell, cell, cell, cell)
				end
			end
		end
	end

	return string.format(
		"<svg viewBox=\"0 0 %d %d\"><path d=\"%s\"/></svg>",
		PATTERN_SIZE,
		PATTERN_SIZE,
		table.concat(parts)
	)
end

local function pattern_panel(svg, background, foreground)
	return Panel.New{
		transform = true,
		layout = {
			MinSize = Vec2(PATTERN_SIZE + 16, PATTERN_SIZE + 16),
			MaxSize = Vec2(PATTERN_SIZE + 16, PATTERN_SIZE + 16),
		},
		visual = {
			OnDraw = function(self)
				local size = self.Owner.transform:GetSize()
				render2d.SetColor(background:Unpack())
				render2d.DrawRect(0, 0, size.x, size.y)
				render2d.SetColor(foreground:Unpack())
				render2d.PushMatrixf(8, 8, PATTERN_SIZE, PATTERN_SIZE)
				svg:Draw()
				render2d.PopMatrix()
			end,
		},
	}
end

return {
	Name = "subpixel",
	Section = "Foundations",
	Order = 1.5,
	Create = function()
		local layouts = {}

		for _, value in ipairs(pvars.GetAll()["r_text_subpixel"].enums) do
			layouts[#layouts + 1] = {Text = layout_labels[value], Value = value}
		end

		local note = Text{
			Text = render2d.SupportsSubpixelText() and
				"Applies to MSDF text and icons drawn straight to the window. Outlines and glows stay grayscale." or
				"This GPU has no dual source blending, so subpixel rendering is unavailable.",
			Color = "text_disabled",
			IgnoreMouseInput = true,
		}
		local pattern_rows = {}

		for _, pattern in ipairs(patterns) do
			local svg = SVG.New(
				build_pattern_source(pattern.kind, pattern.cell),
				{TextureSize = PATTERN_SIZE, Mode = "msdf"}
			)
			local panels = {}

			for _, swatch in ipairs(backgrounds) do
				panels[#panels + 1] = pattern_panel(svg, swatch.background, swatch.foreground)
			end

			pattern_rows[#pattern_rows + 1] = kit.Labeled(pattern.name, kit.Group(panels, {GrowWidth = 0, FitWidth = true, ChildGap = "XS"}))
		end

		local swatches = {}

		for _, swatch in ipairs(backgrounds) do
			local lines = {}

			for _, size in ipairs(text_sizes) do
				lines[#lines + 1] = Text{
					Text = string.format("Hamburgefonstiv 1lI| design tokens %dpx", size),
					Font = fonts.New{Size = size},
					Color = swatch.foreground,
					IgnoreMouseInput = true,
				}
			end

			swatches[#swatches + 1] = kit.Labeled(
				swatch.name,
				Column{
					Padding = "S",
					swatch_background = swatch.background,
					visual = true,
					OnDraw = function(self)
						render2d.SetColor(self.swatch_background:Unpack())
						render2d.DrawRect(0, 0, self.transform:GetWidth(), self.transform:GetHeight())
					end,
					layout = {AlignmentX = "start", ChildGap = "XXS", GrowWidth = 0, FitWidth = true},
				}(lines)
			)
		end

		return kit.Page{
			Title = "Subpixel",
			Description = "Text and icons can use the pixel layout of the display for extra horizontal detail. Pick the layout of your display, then check the patterns below.",
		}{
			kit.Section{
				Title = "Layout",
				Description = "r_text_subpixel is the pixel layout. r_text_subpixel_strength blends between grayscale and the full per colour result.",
			}{
				kit.Labeled(
					"r_text_subpixel",
					Dropdown{
						Options = layouts,
						Value = pvars.Get("r_text_subpixel"),
						OnSelect = function(value)
							pvars.Set("r_text_subpixel", value)
						end,
					}
				),
				kit.SliderRow{
					Label = "Strength",
					Value = math.floor(pvars.Get("r_text_subpixel_strength") * 100 + 0.5),
					Min = 0,
					Max = 100,
					Suffix = "%",
					OnChange = function(value)
						pvars.Set("r_text_subpixel_strength", value / 100)
					end,
				},
				note,
			},
			kit.Section{
				Title = "Lines and checkerboards",
				Description = "One pixel patterns drawn 1:1. The right layout keeps them neutral grey, the wrong one tints them.",
			}{
				kit.Wrap(pattern_rows, {ChildGap = "L"}),
			},
			kit.Section{
				Title = "Small sizes",
				Description = "Fixed pixel sizes that ignore the theme.",
			}{
				kit.Wrap(swatches, {ChildGap = "L"}),
			},
		}
	end,
}
