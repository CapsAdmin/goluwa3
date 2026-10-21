local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local InputHistory = import("goluwa/input_history.lua")
local autocomplete = import("goluwa/autocomplete.lua")
local command_input = import("goluwa/cli/command_input.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local WORDS = {
	"entity",
	"entity_tree",
	"event",
	"event_listener",
	"texture",
	"text_edit",
	"text_flow",
	"theme",
	"theme_token",
	"tooltip",
	"transform",
	"tree_node",
	"virtual_grid",
	"vertex_buffer",
	"window",
	"world_matrix",
}
local MORE_WORDS = {"render2d", "render3d", "renderer", "scrollable_panel", "scene_view"}
local HISTORY_ENTRIES = {"first command", "second command", "print('hello')", "third command"}
autocomplete.AddList("gallery_words", WORDS)
autocomplete.AddList("gallery_more_words", MORE_WORDS)
autocomplete.SetListName("gallery_more_words", "Rendering")

local function new_words_session()
	return autocomplete.NewSession{Lists = {"gallery_words", "gallery_more_words"}}
end

local function draw_backdrop(backdrop)
	local size = backdrop.transform:GetSize()
	render2d.SetTexture()
	render2d.SetColor(0.08, 0.1, 0.14, 1)
	render2d.DrawRect(0, 0, size.x, size.y)
end

local AssistedEdit = react.Component(|props| -> do
	local edit, set_edit = react.UseState()
	local session = react.UseMemo(|| -> props.NewSession and props.NewSession(), {})

	return {
		ui.TextEdit{
			Ref = set_edit,
			Hint = props.Hint,
			Autocomplete = session,
			History = props.History,
			OnKeyInput = props.OnKeyInput,
			OnHistoryNavigate = props.OnHistoryNavigate,
		},
		props.Popup ~= false && edit && react.Portal{Target = Panel.World}{
			ui.AutocompleteList{Target = edit, Transparent = props.Transparent, MaxRows = 6},
		},
	}
end)

return {
	Name = "input assist",
	Section = "Controls",
	Order = 4.5,
	View = react.Component(|| -> do
		local history = react.UseMemo(|| -> do
			local entries = InputHistory.New()

			for _, entry in ipairs(HISTORY_ENTRIES) do
				entries:Add(entry)
			end

			return entries
		end, {})
		local readout, set_readout = react.UseState("draft (4 entries)")
		local log, set_log = react.UseState("nothing submitted yet")

		return kit.Page{
			Title = "Input assist",
			Description = "History and autocomplete are properties of TextEdit, the logic lives in goluwa/input_history.lua and goluwa/autocomplete.lua, undo in goluwa/text_undo.lua.",
		}{
			kit.Section{
				Title = "Undo and context menu",
				Description = "Every TextEdit has an undo history (Ctrl+Z, Ctrl+Y or Ctrl+Shift+Z): typed words and runs of backspaces are one step, pastes and recalled history entries are their own. Right click opens a menu with undo, redo, cut, copy, paste and select all, ContextMenu = false turns it off.",
			}{
				ui.TextEdit{Text = "Type here, then undo it. Right click for the menu."},
			},
			kit.Section{
				Title = "History",
				Description = "Enter submits. Up and Down recall earlier input (Up on the first line, Down on the last), the draft comes back after the newest entry, Ctrl+Up only recalls entries that start with what you typed, Ctrl+R searches the whole history (Enter picks a match, Escape cancels, needs an AutocompleteList to show the matches).",
			}{
				AssistedEdit{
					Hint = "press up for earlier input",
					History = history,
					OnKeyInput = |text_edit, key, press| -> do
						if key == "enter" and press and text_edit:GetText() ~= "" then
							text_edit:CommitHistory()
							set_log("submitted: " .. text_edit:GetText())
							text_edit:SetText("")
							set_readout("draft (" .. history:GetCount() .. " entries)")

							return true
						end
					end,
					OnHistoryNavigate = |_, index, count| -> set_readout(
						index and ("entry " .. index .. " of " .. count) or ("draft (" .. count .. " entries)")
					),
				},
				ui.Text{Text = readout, Color = "text_disabled", IgnoreMouseInput = true},
				ui.Text{Text = log, Color = "text_disabled", IgnoreMouseInput = true},
			},
			kit.Section{
				Title = "Ghost text",
				Description = "Autocomplete = session shows the best completion as gray text. Tab accepts it and cycles through more, Right accepts at the end of the text.",
			}{
				AssistedEdit{Hint = "type t, e or r", NewSession = new_words_session, Popup = false},
			},
			kit.Section{
				Title = "Suggestion list",
				Description = "AutocompleteList follows the input and the theme. Up and Down pick an entry, Enter accepts a picked entry, Escape closes the list, clicking an entry accepts it. Lists can have names for headers.",
			}{
				AssistedEdit{Hint = "type t, e or r", NewSession = new_words_session},
			},
			kit.Section{
				Title = "Command line",
				Description = "Text that starts with ! completes the engine's console commands and variables with their syntax (command_input.NewSession, nothing is run here), once a command is typed the list shows its usage, for a variable its type, value and the values it accepts. The chat runs these lines with command_input.Run and prints the output.",
			}{
				AssistedEdit{Hint = "try !help or !", NewSession = command_input.NewSession},
			},
			kit.Section{
				Title = "Transparent list",
				Description = "Transparent = true draws no background, for overlays on top of a scene.",
			}{
				ui.Panel{
					transform = true,
					visual = true,
					OnDraw = draw_backdrop,
					layout = {
						Direction = "y",
						GrowWidth = 1,
						MinSize = Vec2(0, 150),
						MaxSize = Vec2(0, 150),
						Padding = "M",
					},
				}{
					AssistedEdit{Hint = "type t, e or r", NewSession = new_words_session, Transparent = true},
				},
			},
		}
	end),
}
