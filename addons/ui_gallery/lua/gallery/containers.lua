local Vec2 = import("goluwa/structs/vec2.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")

local function pane(title)
	return ui.Frame{Padding = "S", layout = {GrowWidth = 1, GrowHeight = 1}}{
		ui.Text{Text = title, Font = "body_strong S", IgnoreMouseInput = true},
		ui.Text{
			Text = "Drag the divider to resize the panes.",
			Color = "text_disabled",
			Wrap = true,
			IgnoreMouseInput = true,
			layout = {GrowWidth = 1},
		},
	}
end

return {
	Name = "containers",
	Section = "Containers",
	Order = 1,
	View = react.Component(|| -> do
		local readout, set_readout = react.UseState("OnToggle has not fired yet")
		local collapsed, set_collapsed = react.UseState({first = false, nested = true, filled = true})

		-- the widgets toggle themselves when clicked, the state follows what they report
		local function on_toggle(key)
			return |is_collapsed| -> do
				set_readout("OnToggle(" .. tostring(is_collapsed) .. ")")
				set_collapsed(|current| -> table.merge(table.shallow_copy(current), {[key] = is_collapsed}))
			end
		end

		local function set_all(value)
			set_collapsed({first = value, nested = value, filled = value})
		end

		return kit.Page{
			Title = "Containers",
			Description = "Frames, collapsible sections and splitters.",
		}{
			kit.Section{
				Title = "Frame",
				Description = "A themed surface. Emphasis raises it for popups and windows.",
			}{
				kit.Group(
					list.map(
						{0, 1, 2, 3},
						|level| -> kit.Labeled(
							"Emphasis = " .. level,
							ui.Frame{
								Emphasis = level,
								Padding = "M",
								layout = {MinSize = Vec2(120, 64), MaxSize = Vec2(120, 64)},
							}{
								ui.Text{Text = "Frame", IgnoreMouseInput = true},
							}
						)
					),
					{AlignmentY = "start"}
				),
			},
			kit.Section{
				Title = "Collapsible",
				Description = "Children go into the body. SetCollapsed animates and fires OnToggle(collapsed, collapsible).",
			}{
				kit.Group{
					ui.Button{Text = "Collapse all", Mode = "outline", OnClick = || -> set_all(true)},
					ui.Button{Text = "Expand all", Mode = "outline", OnClick = || -> set_all(false)},
				},
				ui.Collapsible{Title = "Information", Collapsed = collapsed.first, OnToggle = on_toggle("first")}{
					ui.Text{
						Text = kit.Lorem,
						Wrap = true,
						IgnoreMouseInput = true,
						layout = {GrowWidth = 1},
					},
				},
				ui.Collapsible{Title = "Nested", Collapsed = collapsed.nested, OnToggle = on_toggle("nested")}{
					ui.Collapsible{
						Title = "Inner",
						Collapsed = true,
						HeaderMode = "text",
						OnToggle = |is_collapsed| -> set_readout("OnToggle(" .. tostring(is_collapsed) .. ")"),
					}{
						ui.Text{Text = "Collapsibles can be nested to any depth.", IgnoreMouseInput = true},
					},
					ui.Button{Text = "A button inside the body", Mode = "outline"},
				},
				ui.Collapsible{
					Title = "Filled header",
					Collapsed = collapsed.filled,
					HeaderMode = "filled",
					HeaderButtonColor = "positive",
					HeaderTextColor = "text_on_accent",
					OnToggle = on_toggle("filled"),
				}{
					ui.Text{
						Text = "HeaderMode, HeaderButtonColor and HeaderTextColor restyle the header.",
						Wrap = true,
						IgnoreMouseInput = true,
						layout = {GrowWidth = 1},
					},
				},
				ui.Text{Text = readout, Color = "text_disabled", IgnoreMouseInput = true},
			},
			kit.Section{
				Title = "Splitter",
				Description = "Two children separated by a draggable divider. Vertical = true stacks them.",
			}{
				ui.Splitter{InitialSize = 240, layout = {MinSize = Vec2(0, 140), MaxSize = Vec2(0, 140)}}{
					pane("Left"),
					pane("Right"),
				},
				ui.Splitter{
					Vertical = true,
					InitialSize = 60,
					MinSplitSize = 40,
					layout = {MinSize = Vec2(0, 200), MaxSize = Vec2(0, 200)},
				}{
					pane("Top"),
					pane("Bottom"),
				},
			},
		}
	end),
}
