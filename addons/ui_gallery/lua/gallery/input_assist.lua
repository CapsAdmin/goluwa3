local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local AutocompleteList = import("goluwa/render2d/ui/widgets/autocomplete_list.lua")
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
autocomplete.AddList("gallery_words", WORDS)
autocomplete.AddList("gallery_more_words", MORE_WORDS)
autocomplete.SetListName("gallery_more_words", "Rendering")

local function update_history_readout(text_edit, index, count)
	text_edit.Readout.text:SetText(
		index and
			("entry " .. index .. " of " .. count) or
			("draft (" .. count .. " entries)")
	)
end

local function submit_history(text_edit, key, press)
	if key == "enter" and press and text_edit:GetText() ~= "" then
		text_edit:CommitHistory()
		text_edit.Log.text:SetText("submitted: " .. text_edit:GetText())
		text_edit:SetText("")
		update_history_readout(text_edit, nil, text_edit.History:GetCount())
		return true
	end
end

local function create_history_demo()
	local history = InputHistory.New()

	for _, entry in ipairs{"first command", "second command", "print('hello')", "third command"} do
		history:Add(entry)
	end

	local readout = Text{Text = "draft (4 entries)", Color = "text_disabled", IgnoreMouseInput = true}
	local log = Text{Text = "nothing submitted yet", Color = "text_disabled", IgnoreMouseInput = true}
	local text_edit = TextEdit{
		History = history,
		Readout = readout,
		Log = log,
		Hint = "press up for earlier input",
		OnKeyInput = submit_history,
		OnHistoryNavigate = update_history_readout,
	}
	AutocompleteList{Target = text_edit, MaxRows = 6}
	return text_edit, readout, log
end

local function create_autocomplete(options)
	options = options or {}
	local session = autocomplete.NewSession{Lists = {"gallery_words", "gallery_more_words"}}
	local text_edit = TextEdit{Hint = "type t, e or r", Autocomplete = session}

	if options.popup ~= false then
		AutocompleteList{Target = text_edit, Transparent = options.transparent, MaxRows = 6}
	end

	return text_edit
end

local function create_command_line()
	local text_edit = TextEdit{Hint = "try !help or !", Autocomplete = command_input.NewSession()}
	AutocompleteList{Target = text_edit, MaxRows = 6}
	return text_edit
end

return {
	Name = "input assist",
	Section = "Controls",
	Order = 4.5,
	Create = function()
		local history_edit, history_readout, history_log = create_history_demo()
		local backdrop = Panel.New{
			transform = true,
			visual = true,
			OnDraw = function(backdrop)
				local size = backdrop.transform:GetSize()
				local render2d = import("goluwa/render2d/render2d.lua")
				render2d.SetTexture()
				render2d.SetColor(0.08, 0.1, 0.14, 1)
				render2d.DrawRect(0, 0, size.x, size.y)
			end,
			layout = {
				Direction = "y",
				GrowWidth = 1,
				MinSize = Vec2(0, 150),
				MaxSize = Vec2(0, 150),
				Padding = "M",
			},
		}{create_autocomplete{transparent = true}}
		return kit.Page{
			Title = "Input assist",
			Description = "History and autocomplete are properties of TextEdit, the logic lives in goluwa/input_history.lua and goluwa/autocomplete.lua, undo in goluwa/text_undo.lua.",
		}{
			kit.Section{
				Title = "Undo and context menu",
				Description = "Every TextEdit has an undo history (Ctrl+Z, Ctrl+Y or Ctrl+Shift+Z): typed words and runs of backspaces are one step, pastes and recalled history entries are their own. Right click opens a menu with undo, redo, cut, copy, paste and select all, ContextMenu = false turns it off.",
			}{
				TextEdit{Text = "Type here, then undo it. Right click for the menu."},
			},
			kit.Section{
				Title = "History",
				Description = "Enter submits. Up and Down recall earlier input (Up on the first line, Down on the last), the draft comes back after the newest entry, Ctrl+Up only recalls entries that start with what you typed, Ctrl+R searches the whole history (Enter picks a match, Escape cancels, needs an AutocompleteList to show the matches).",
			}{
				history_edit,
				history_readout,
				history_log,
			},
			kit.Section{
				Title = "Ghost text",
				Description = "Autocomplete = session shows the best completion as gray text. Tab accepts it and cycles through more, Right accepts at the end of the text.",
			}{
				create_autocomplete{popup = false},
			},
			kit.Section{
				Title = "Suggestion list",
				Description = "AutocompleteList follows the input and the theme. Up and Down pick an entry, Enter accepts a picked entry, Escape closes the list, clicking an entry accepts it. Lists can have names for headers.",
			}{
				create_autocomplete(),
			},
			kit.Section{
				Title = "Command line",
				Description = "Text that starts with ! completes the engine's console commands and variables with their syntax (command_input.NewSession, nothing is run here), once a command is typed the list shows its usage, for a variable its type, value and the values it accepts. The chat runs these lines with command_input.Run and prints the output.",
			}{
				create_command_line(),
			},
			kit.Section{
				Title = "Transparent list",
				Description = "Transparent = true draws no background, for overlays on top of a scene.",
			}{
				backdrop,
			},
		}
	end,
}
