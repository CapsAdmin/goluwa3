local Vec2 = import("goluwa/structs/vec2.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local kit = {}

function kit.Page(props)
	return ui.Column{
		layout = {
			Direction = "y",
			GrowWidth = 1,
			FitHeight = true,
			AlignmentX = "stretch",
			ChildGap = "L",
			Padding = "M",
		},
	}{
		ui.Column{
			Key = "header",
			layout = {
				Direction = "y",
				GrowWidth = 1,
				FitHeight = true,
				AlignmentX = "stretch",
				ChildGap = "XS",
			},
		}{
			ui.Text{Key = "title", Text = props.Title, Font = "heading XL", IgnoreMouseInput = true},
			props.Description && ui.Text{
				Key = "description",
				Text = props.Description,
				Color = "text_disabled",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {GrowWidth = 1},
			},
		},
	}
end

do
	local STAGE_LAYOUT = {
		Direction = "y",
		GrowWidth = 1,
		FitHeight = true,
		AlignmentX = "stretch",
		ChildGap = "M",
	}

	kit.Section = react.Component(|props| -> do
		local stage

		if props.Framed == false then
			stage = ui.Panel{Key = "stage", transform = true, layout = STAGE_LAYOUT}{props.children}
		else
			stage = ui.Frame{Key = "stage", Padding = "M", layout = STAGE_LAYOUT}{props.children}
		end

		return ui.Column{
			layout = {
				Direction = "y",
				GrowWidth = 1,
				FitHeight = true,
				AlignmentX = "stretch",
				ChildGap = "S",
			},
		}{
			ui.Text{Key = "title", Text = props.Title, Font = "body_strong M", IgnoreMouseInput = true},
			props.Description && ui.Text{
				Key = "description",
				Text = props.Description,
				Font = "body S",
				Color = "text_disabled",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {GrowWidth = 1},
			},
			stage,
		}
	end)
end

function kit.Caption(text)
	return ui.Text{Text = text, Font = "body XS", Color = "text_disabled", IgnoreMouseInput = true}
end

function kit.Group(children, layout)
	return ui.Row{
		layout = table.merge(
			{
				ChildGap = "S",
				AlignmentY = "center",
				GrowWidth = 1,
				FitHeight = true,
			},
			layout or {}
		),
	}{children}
end

function kit.Wrap(children, layout)
	return kit.Group(children, table.merge({WrapChildren = true}, layout or {}))
end

function kit.Labeled(caption, child)
	return ui.Column{
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

	return ui.Text{
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

kit.SliderRow = react.Component(|props| -> do
	local value, set_value = react.UseState(props.Value)

	return ui.Row{layout = {ChildGap = "S", GrowWidth = 1, AlignmentY = "center"}}{
		ui.Text{
			Text = props.Label,
			IgnoreMouseInput = true,
			layout = {MinSize = Vec2(72, 0), FitWidth = false},
		},
		ui.Slider{
			Value = props.Value,
			Min = props.Min,
			Max = props.Max,
			OnChange = |slider_value| -> do
				local rounded = math.floor(slider_value + 0.5)
				set_value(rounded)
				props.OnChange(rounded)
			end,
			layout = {GrowWidth = 1},
		},
		ui.Text{
			Text = value .. (props.Suffix ?? ""),
			AlignX = 1,
			IgnoreMouseInput = true,
			layout = {MinSize = Vec2(48, 0), FitWidth = false},
		},
	}
end)

kit.Lorem = "The quick brown fox jumps over the lazy dog while the five boxing wizards jump quickly. Pack my box with five dozen liquor jugs, and sphinx of black quartz, judge my vow."

return kit
