local Vec2 = import("goluwa/structs/vec2.lua")
local Collapsible = import("goluwa/render2d/ui/widgets/collapsible.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Frame = import("goluwa/render2d/ui/elements/frame.lua")
local Splitter = import("goluwa/render2d/ui/elements/splitter.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")

local function pane(title)
	return Frame{Padding = "S", layout = {GrowWidth = 1, GrowHeight = 1}}{
		Text{Text = title, Font = "body_strong S", IgnoreMouseInput = true},
		Text{
			Text = "Drag the divider to resize the panes.",
			Color = "text_disabled",
			Wrap = true,
			IgnoreMouseInput = true,
			layout = {GrowWidth = 1},
		},
	}
end

local function on_toggle(collapsed, collapsible)
	collapsible.Readout.text:SetText("OnToggle(" .. tostring(collapsed) .. ")")
end

local function toggle_all(button)
	for _, collapsible in ipairs(button.Targets) do
		collapsible:SetCollapsed(button.Collapse)
	end
end

return {
	Name = "containers",
	Section = "Containers",
	Order = 1,
	Create = function()
		local readout = Text{
			Text = "OnToggle has not fired yet",
			Color = "text_disabled",
			IgnoreMouseInput = true,
		}
		local first = Collapsible{Title = "Information", Readout = readout, OnToggle = on_toggle}{
			Text{
				Text = kit.Lorem,
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {GrowWidth = 1},
			},
		}
		local nested = Collapsible{Title = "Nested", Collapsed = true, Readout = readout, OnToggle = on_toggle}{
			Collapsible{
				Title = "Inner",
				Collapsed = true,
				HeaderMode = "text",
				Readout = readout,
				OnToggle = on_toggle,
			}{
				Text{Text = "Collapsibles can be nested to any depth.", IgnoreMouseInput = true},
			},
			Button{Text = "A button inside the body", Mode = "outline"},
		}
		local filled = Collapsible{
			Title = "Filled header",
			Collapsed = true,
			HeaderMode = "filled",
			HeaderButtonColor = "positive",
			HeaderTextColor = "text_on_accent",
			Readout = readout,
			OnToggle = on_toggle,
		}{
			Text{
				Text = "HeaderMode, HeaderButtonColor and HeaderTextColor restyle the header.",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {GrowWidth = 1},
			},
		}
		local emphases = {}

		for level = 0, 3 do
			emphases[#emphases + 1] = kit.Labeled(
				"Emphasis = " .. level,
				Frame{
					Emphasis = level,
					Padding = "M",
					layout = {MinSize = Vec2(120, 64), MaxSize = Vec2(120, 64)},
				}{
					Text{Text = "Frame", IgnoreMouseInput = true},
				}
			)
		end

		return kit.Page{
			Title = "Containers",
			Description = "Frames, collapsible sections and splitters.",
		}{
			kit.Section{
				Title = "Frame",
				Description = "A themed surface. Emphasis raises it for popups and windows.",
			}{kit.Group(emphases, {AlignmentY = "start"})},
			kit.Section{
				Title = "Collapsible",
				Description = "Children go into the body. SetCollapsed animates and fires OnToggle(collapsed, collapsible).",
			}{
				kit.Group{
					Button{
						Targets = {first, nested, filled},
						Collapse = true,
						Text = "Collapse all",
						Mode = "outline",
						OnClick = toggle_all,
					},
					Button{
						Targets = {first, nested, filled},
						Collapse = false,
						Text = "Expand all",
						Mode = "outline",
						OnClick = toggle_all,
					},
				},
				first,
				nested,
				filled,
				readout,
			},
			kit.Section{
				Title = "Splitter",
				Description = "Two children separated by a draggable divider. Vertical = true stacks them.",
			}{
				Splitter{InitialSize = 240, layout = {MinSize = Vec2(0, 140), MaxSize = Vec2(0, 140)}}{
					pane("Left"),
					pane("Right"),
				},
				Splitter{
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
	end,
}
