local Vec2 = import("goluwa/structs/vec2.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local Slider = import("goluwa/render2d/ui/elements/slider.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local Page = import("addons/ui_gallery/lua/gallery_page.lua")
local Section = import("addons/ui_gallery/lua/gallery_section.lua")
local kit = {Page = Page, Section = Section}

function kit.Caption(text)
	return Text{
		Text = text,
		Font = "body XS",
		Color = "text_disabled",
		IgnoreMouseInput = true,
	}
end

function kit.Group(children, layout)
	return Row{
		layout = table.merge(
			{
				ChildGap = "S",
				AlignmentY = "center",
				GrowWidth = 1,
				FitHeight = true,
			},
			layout or {}
		),
	}(children)
end

function kit.Wrap(children, layout)
	return kit.Group(children, table.merge({WrapChildren = true}, layout or {}))
end

function kit.Labeled(caption, child)
	return Column{
		layout = {
			ChildGap = "XXS",
			AlignmentX = "start",
			GrowWidth = 0,
			FitWidth = true,
		},
	}{
		kit.Caption(caption),
		child,
	}
end

function kit.Paragraph(text, props)
	props = props or {}
	return Text{
		Text = text,
		Wrap = true,
		Font = props.Font,
		Color = props.Color,
		AlignX = props.AlignX,
		Justify = props.Justify,
		IgnoreMouseInput = true,
		layout = {GrowWidth = 1},
	}
end

local function on_row_slider_change(value, slider)
	local row = slider.SliderRow
	value = math.floor(value + 0.5)
	row.ValueLabel.text:SetText(value .. row.Suffix)
	row.OnValueChange(value)
end

function kit.SliderRow(props)
	local row = Row{
		Suffix = props.Suffix or "",
		OnValueChange = props.OnChange,
		layout = {
			ChildGap = "S",
			GrowWidth = 1,
			AlignmentY = "center",
		},
	}
	row.ValueLabel = Text{
		Text = props.Value .. row.Suffix,
		AlignX = 1,
		IgnoreMouseInput = true,
		layout = {MinSize = Vec2(48, 0), FitWidth = false},
	}
	row{
		Text{
			Text = props.Label,
			IgnoreMouseInput = true,
			layout = {MinSize = Vec2(72, 0), FitWidth = false},
		},
		Slider{
			SliderRow = row,
			Value = props.Value,
			Min = props.Min,
			Max = props.Max,
			OnChange = on_row_slider_change,
			layout = {GrowWidth = 1},
		},
		row.ValueLabel,
	}
	return row
end

kit.Lorem = "The quick brown fox jumps over the lazy dog while the five boxing wizards jump quickly. Pack my box with five dozen liquor jugs, and sphinx of black quartz, judge my vow."
return kit
