local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local event = import("goluwa/event.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local editor_history = import("lua/editor_history.lua")
local history = editor_history.history
return function(props)
	props = props or {}
	local window
	local list_column
	local undo_button
	local redo_button
	local clear_button
	local dirty = false

	local function add_row(index, name)
		local current = history:GetIndex()
		list_column:AddChild(
			Button{
				Text = index == 0 and name or (index .. "  " .. name),
				Mode = "menu",
				Active = index == current,
				TextColor = index > current and "text_disabled" or nil,
				AlignX = 0,
				OnClick = function()
					history:GoTo(index)
				end,
				layout = {GrowWidth = 1, FitWidth = false},
			}
		)
	end

	local function refresh()
		list_column:RemoveChildren()
		add_row(0, "original state")

		for i, entry in ipairs(history:GetEntries()) do
			add_row(i, entry.Name)
		end

		undo_button:SetDisabled(not history:CanUndo())
		redo_button:SetDisabled(not history:CanRedo())
		clear_button:SetDisabled(#history:GetEntries() == 0)
	end

	window = Window{
		Key = props.Key or "EditorHistoryWindow",
		Title = "HISTORY",
		Size = props.Size or Vec2(300, 420),
		Position = props.Position or Vec2(420, 80),
		MinSize = Vec2(220, 200),
		Padding = "S",
	}{
		Row{layout = {GrowWidth = 1, ChildGap = "XS"}}{
			Button{
				Ref = function(self)
					undo_button = self
				end,
				Text = "Undo",
				Icon = "undo",
				Mode = "outline",
				OnClick = function()
					history:Undo()
				end,
			},
			Button{
				Ref = function(self)
					redo_button = self
				end,
				Text = "Redo",
				Icon = "redo",
				Mode = "outline",
				OnClick = function()
					history:Redo()
				end,
			},
			Button{
				Ref = function(self)
					clear_button = self
				end,
				Text = "Clear",
				Icon = "trash",
				Mode = "outline",
				OnClick = function()
					history:Clear()
				end,
			},
		},
		ScrollablePanel{
			ScrollX = false,
			ScrollY = true,
			Padding = Rect(),
			layout = {GrowWidth = 1, GrowHeight = 1},
		}{
			Column{
				Ref = function(self)
					list_column = self
				end,
				layout = {
					GrowWidth = 1,
					ChildGap = 0,
					AlignmentX = "stretch",
				},
			},
		},
	}
	event.AddListener("HistoryChanged", window, function()
		dirty = true
	end)

	function window:OnUpdate()
		if dirty then
			dirty = false
			refresh()
		end
	end

	window:AddGlobalEvent("Update")
	window:CallOnRemove(
		function()
			event.RemoveListener("HistoryChanged", window)
		end,
		"editor_history_panel"
	)
	refresh()
	return window
end
