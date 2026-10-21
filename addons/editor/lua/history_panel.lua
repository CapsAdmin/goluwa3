local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local react = import("goluwa/render2d/ui/react.lua")
local Window = react.Element(import("goluwa/render2d/ui/widgets/window.lua"))
local Button = react.Element(import("goluwa/render2d/ui/widgets/button.lua"))
local Column = react.Element(import("goluwa/render2d/ui/elements/column.lua"))
local Row = react.Element(import("goluwa/render2d/ui/elements/row.lua"))
local ScrollablePanel = react.Element(import("goluwa/render2d/ui/elements/scrollable_panel.lua"))
local editor_history = import("lua/editor_history.lua")
local history = editor_history.history
local HistoryRow = react.Memo(
	react.Component(
		|props|->Button{
			Text = props.Index == 0 and props.Name or props.Index .. "  " .. props.Name,
			Mode = "menu",
			Active = props.Active,
			TextColor = props.Future ? "text_disabled" : nil,
			AlignX = 0,
			OnClick = ||->history:GoTo(props.Index),
			layout = {GrowWidth = 1, FitWidth = false},
		}
	)
)
local HistoryView = react.Component(
	|props|-> do
		local _, set_version = react.UseState(0)
		local position = react.UseMemo(||->props.Position ?? Vec2(420, 80), {})
		react.UseEvent("HistoryChanged", ||->set_version(|version|->version + 1))
		local current = history:GetIndex()
		local entries = history:GetEntries()
		local rows = {
			HistoryRow{
				Key = 0,
				Index = 0,
				Name = "original state",
				Active = current == 0,
				Future = false,
			},
		}

		for index, entry in ipairs(entries) do
			rows[index + 1] = HistoryRow{
				Key = index,
				Index = index,
				Name = entry.Name,
				Active = index == current,
				Future = index > current,
			}
		end

		return Window{
			Title = "HISTORY",
			Size = props.Size ?? Vec2(300, 420),
			Position = position,
			MinSize = Vec2(220, 200),
			Padding = "S",
		}{
			Row{layout = {GrowWidth = 1, ChildGap = "XS"}}{
				Button{
					Text = "Undo",
					Icon = "undo",
					Mode = "outline",
					Disabled = not history:CanUndo(),
					OnClick = ||->history:Undo(),
				},
				Button{
					Text = "Redo",
					Icon = "redo",
					Mode = "outline",
					Disabled = not history:CanRedo(),
					OnClick = ||->history:Redo(),
				},
				Button{
					Text = "Clear",
					Icon = "trash",
					Mode = "outline",
					Disabled = #entries == 0,
					OnClick = ||->history:Clear(),
				},
			},
			ScrollablePanel{
				ScrollX = false,
				ScrollY = true,
				Padding = Rect(),
				layout = {GrowWidth = 1, GrowHeight = 1},
			}{
				Column{layout = {GrowWidth = 1, ChildGap = 0, AlignmentX = "stretch"}}{rows},
			},
		}
	end
)
return function(props)
	return react.OpenWindow("EditorHistoryWindow", HistoryView, props)
end
