local Vec2 = import("goluwa/structs/vec2.lua")
local system = import("goluwa/system.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local utf8 = import("goluwa/string/utf8.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local input = import("goluwa/input.lua")
local autocomplete = import("goluwa/autocomplete.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local MenuSpacer = import("goluwa/render2d/ui/elements/menu_spacer.lua")
local META = Panel:CreateTemplate("text_edit")
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "y",
	GrowWidth = 1,
}
META.CMP.visual = {}
META.CMP.mouse_input = {}
META:StartStorable()
META:GetSet("Text", "")
META:GetSet("Hint", "")
META:GetSet("Editable", true)
META:GetSet("Wrap", false)
META:GetSet("ScrollX", nil)
META:GetSet("ScrollY", false)
META:GetSet("ScrollbarVisible", true)
META:GetSet("ScrollbarAutoHide", true)
META:GetSet("Font", nil)
META:GetSet("FontSize", nil)
META:GetSet("TextColor", nil)
META:GetSet("SelectionColor", nil)
META:GetSet("PanelColor", "surface_alt")
META:GetSet("Padding", nil)
META:GetSet("AutoResize", false)
META:GetSet("AutoScrollToCaret", true)
META:GetSet("MaxLines", 4)
META:GetSet("History", nil)
META:GetSet("Autocomplete", nil)
META:GetSet("AutocompleteGhost", true)
META:GetSet("ContextMenu", true)
META:EndStorable()

function META.OnTextChanged(text_edit, text, old_text) end

function META.OnKeyInput(text_edit, key, press) end

function META.OnKeyInputRepeat(text_edit, key) end

function META.OnHistoryNavigate(text_edit, index, count) end

function META.OnHistorySearch(text_edit, active) end

local last_focused_text

local function on_text_focus(text)
	text.mouse_input:SetRequestMouse(true)

	if last_focused_text and last_focused_text ~= text and last_focused_text:IsValid() then
		last_focused_text.text.editor:SetSelectionStart(nil)
	end

	last_focused_text = text
end

local function on_text_unfocus(text)
	text.mouse_input:SetRequestMouse(false)
end

local function on_text_cursor_moved(text)
	text.TextEdit:sync_text_changed()
end

local function on_text_key_input(text, key, press)
	local text_edit = text.TextEdit

	if press then
		if text_edit.History and text_edit:history_search_key(key) then return true end

		if text_edit.Autocomplete and text_edit:autocomplete_key(key) then return true end

		if text_edit.History and text_edit:navigate_history(key) then return true end
	end

	return text_edit.OnKeyInput(text_edit, key, press)
end

local function on_text_key_input_repeat(text, key)
	local text_edit = text.TextEdit

	if text_edit.History and text_edit:history_search_key(key) then return true end

	if text_edit.Autocomplete and text_edit:autocomplete_key(key) then return true end

	if text_edit.History and text_edit:navigate_history(key) then return true end

	return text_edit.OnKeyInputRepeat(text_edit, key)
end

local function run_menu_action(item)
	local text_edit = item.TextEdit
	text_edit[item.Action](text_edit)
	text_edit:RequestTextFocus()
end

local function forward_mouse_input(surface, button, press)
	if button == "button_2" and press and surface.TextEdit.ContextMenu then
		surface.TextEdit:open_context_menu()
		return true
	end

	local text_panel = surface.TextEdit._text_panel
	local mouse_pos = system.GetWindow():GetMousePosition()
	return text_panel.text:OnMouseInput(button, press, text_panel.transform:GlobalToLocal(mouse_pos))
end

function META.PropDefaults(_, props)
	if props.Size then
		return {MinSize = Vec2(100, props.Size.y), MaxSize = Vec2(0, props.Size.y)}
	end

	return {
		Size = theme.Dynamic(theme.InputSize, 400, props.FontSize),
		MinSize = theme.Dynamic(theme.InputSize, 100, props.FontSize),
		MaxSize = theme.Dynamic(theme.InputSize, 0, props.FontSize),
	}
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	local editable = self.Editable
	local wrap = self.Wrap
	self._last_text = self.Text
	self:SetState("panel_color", self.PanelColor)
	self:SetState("editable", editable)
	self._scroll_panel = ScrollablePanel{
		Parent = self,
		IsInternal = true,
		Name = "scroll_panel",
		Cursor = "text_input",
		ScrollX = self.ScrollX == nil and not wrap or self.ScrollX,
		ScrollY = self.ScrollY,
		ScrollbarVisible = self.ScrollbarVisible,
		ScrollbarAutoHide = self.ScrollbarAutoHide,
		Padding = self:GetPropertyToken("Padding") or "S",
		layout = {
			GrowWidth = 1,
			GrowHeight = 1,
		},
	}

	if not wrap and not self.ScrollY then
		self._scroll_panel.Viewport.layout:SetAlignmentY("center")
	end

	self._text_panel = Text{
		Parent = self._scroll_panel,
		TextEdit = self,
		Text = self.Text,
		Hint = self.Hint,
		Cursor = "text_input",
		Editable = editable,
		Selectable = true,
		Wrap = wrap,
		Color = self.TextColor or "text",
		SelectionColor = self.SelectionColor,
		Font = self.Font,
		OnKeyInput = on_text_key_input,
		OnKeyInputRepeat = on_text_key_input_repeat,
		OnCursorMoved = on_text_cursor_moved,
		OnFocus = on_text_focus,
		OnUnfocus = on_text_unfocus,
		layout = {
			GrowWidth = 1,
			FitWidth = false,
			MinSize = Vec2(1, 0),
		},
	}

	for _, surface in ipairs{self, self._scroll_panel.Viewport} do
		surface.TextEdit = self
		surface:AddLocalListener("OnMouseInput", forward_mouse_input, "text_edit_forward")
		surface.mouse_input:SetFocusOnClick(true)
		surface.mouse_input:SetRedirectFocus(self._text_panel)
	end
end

function META:OnDraw()
	theme.active:Draw(self)
end

function META:OnPostDraw()
	theme.active:DrawPost(self)
end

function META:OnParentVisibilityChanged(visible)
	self:sync_text_changed()
end

function META:sync_text_changed()
	if self.AutoResize then
		local lines, _, vertical_step = self._text_panel.text:GetTextSize2()
		local line_count = math.clamp(lines and #lines or 1, 1, self.MaxLines)
		local padding = self._scroll_panel.Padding
		local w = self.layout:GetMinSize().x
		local h = math.ceil(
			line_count * (
					vertical_step or
					self._text_panel.text:GetFont():GetLineHeight()
				) + padding.y + padding.h
		)
		self.layout:SetMinSize(Vec2(w, h))
		self.layout:SetMaxSize(Vec2(self.layout:GetMaxSize().x, h))
		self._scroll_panel.Viewport.layout:SetAlignmentY(lines and #lines > self.MaxLines and "start" or "center")
	end

	if self.AutoScrollToCaret then
		self._scroll_panel:update_dirty_layout(self._scroll_panel)
		self:scroll_caret_into_view()
	end

	local next_text = self._text_panel.text:GetText()
	local changed = next_text ~= self._last_text
	local old_text = self._last_text
	local session = self.Autocomplete

	if changed then self._last_text = next_text end

	if session then
		if changed then session:SetText(next_text, self._text_panel.text.editor.Cursor) end

		self:update_ghost()
	end

	if changed then self.OnTextChanged(self, next_text, old_text) end
end

function META:update_ghost()
	local text = self._text_panel.text
	local editor = text.editor
	local ghost = ""

	if
		self.AutocompleteGhost and
		not self._search and
		not editor.SelectionStart and
		editor.Cursor == editor.Buffer:GetLength() + 1
	then
		ghost = self.Autocomplete:GetGhost()
	end

	if text.GhostText ~= ghost then text:SetGhostText(ghost) end
end

function META:apply_text(next_text)
	local text = self._text_panel.text
	local editor = text.editor
	editor:SetText(next_text)
	editor.Cursor = editor.Buffer:GetLength() + 1
	editor.SelectionStart = nil
	text.preferred_caret_x = nil
	self:sync_text_changed()
end

function META:autocomplete_key(key)
	local session = self.Autocomplete
	local editor = self._text_panel.text.editor

	if key == "tab" then
		local completion = session:Cycle(editor.ShiftDown and -1 or 1)

		if not completion then return end

		self:apply_text(completion)
		return true
	end

	if not session:HasResults() then return end

	local modified = editor.ShiftDown or input.IsAltDown() or editor.ControlDown

	if key == "escape" then
		session:Dismiss()
		self:update_ghost()
		return true
	end

	if not session:HasSelectable() then return end

	if (key == "up" or key == "down") and not modified then
		session:Move(key == "up" and -1 or 1)
		self:update_ghost()
		return true
	elseif key == "enter" and session:IsExplicit() and not modified then
		self:AcceptAutocomplete()
		return true
	elseif key == "right" and not modified and self._text_panel.text.GhostText ~= "" then
		self:AcceptAutocomplete()
		return true
	end
end

function META:AcceptAutocomplete()
	local completion = self.Autocomplete:Accept()

	if completion then
		if self._search then
			self:end_history_search(false, completion)
		else
			self:apply_text(completion)
		end

		self:RequestTextFocus()
	end
end

function META:history_search_key(key)
	local search = self._search
	local editor = self._text_panel.text.editor

	if search then
		if key == "escape" then
			self:end_history_search(true)
			return true
		elseif key == "enter" or key == "tab" then
			self:end_history_search(false, self.Autocomplete:GetCompletion())
			return true
		elseif key == "r" and editor.ControlDown then
			self.Autocomplete:Move(1)
			return true
		end

		return
	end

	if key == "r" and editor.ControlDown and not editor.ShiftDown and self.History:GetCount() > 0 then
		self:begin_history_search()
		return true
	end
end

function META:begin_history_search()
	local history = self.History
	local id = "history_search_" .. tostring(self)
	autocomplete.AddList(
		id,
		function()
			local entries = history:GetEntries()
			local newest_first = {}

			for i = #entries, 1, -1 do
				newest_first[#newest_first + 1] = entries[i]
			end

			return newest_first
		end,
		{KeepOrder = true}
	)
	autocomplete.SetListName(id, "History search")
	local session = autocomplete.NewSession{Lists = {id}, MinLength = 0, MatchEmpty = true}
	local text = self._text_panel.text
	self._search = {original = self:GetText(), saved = self.Autocomplete, id = id}
	self.Autocomplete = session
	session:SetText(self._search.original, text.editor.Cursor)
	self:update_ghost()
	self.OnHistorySearch(self, true)
end

function META:end_history_search(restore, accepted)
	local search = self._search
	self._search = nil
	autocomplete.RemoveList(search.id)
	autocomplete.SetListName(search.id, nil)
	self.Autocomplete = search.saved
	local text = accepted or (restore and search.original)

	if text then
		self.History:Reset()
		self:apply_text(text)

		if self.Autocomplete then self.Autocomplete:Dismiss() end
	end

	if self.Autocomplete then self:update_ghost() end

	self.OnHistorySearch(self, false)
end

function META:CancelHistorySearch()
	if self._search then self:end_history_search(true) end
end

function META:navigate_history(key)
	if key ~= "up" and key ~= "down" then return end

	local history = self.History
	local text = self._text_panel.text

	if text.editor.ShiftDown or input.IsAltDown() then return end

	local line, line_count = text:GetCaretVisualLine()
	local current = text:GetText()
	local next_text

	if key == "up" then
		if line > 1 or history:GetCount() == 0 then return end

		next_text = history:Older(current, text.editor.ControlDown and current or nil)

		if not next_text then return true end
	else
		if line < line_count or not history:IsBrowsing() then return end

		next_text = history:Newer(current)
	end

	self:apply_text(next_text)
	self.OnHistoryNavigate(self, history:GetIndex(), history:GetCount())
	return true
end

function META:open_context_menu()
	local editor = self._text_panel.text.editor
	local editable = self.Editable
	local has_selection = editor:GetSelection() ~= nil
	local has_clipboard = (editor:GetClipboard() or "") ~= ""
	self:RequestTextFocus()
	Panel.OpenContextMenu(
		{},
		MenuItem{
			TextEdit = self,
			Action = "Undo",
			Text = "Undo",
			Disabled = not (editable and editor:CanUndo()),
			OnClick = run_menu_action,
		},
		MenuItem{
			TextEdit = self,
			Action = "Redo",
			Text = "Redo",
			Disabled = not (editable and editor:CanRedo()),
			OnClick = run_menu_action,
		},
		MenuSpacer{},
		MenuItem{
			TextEdit = self,
			Action = "Cut",
			Text = "Cut",
			Disabled = not (editable and has_selection),
			OnClick = run_menu_action,
		},
		MenuItem{
			TextEdit = self,
			Action = "Copy",
			Text = "Copy",
			Disabled = not has_selection,
			OnClick = run_menu_action,
		},
		MenuItem{
			TextEdit = self,
			Action = "Paste",
			Text = "Paste",
			Disabled = not (editable and has_clipboard),
			OnClick = run_menu_action,
		},
		MenuSpacer{},
		MenuItem{
			TextEdit = self,
			Action = "SelectAll",
			Text = "Select all",
			Disabled = self:GetText() == "",
			OnClick = run_menu_action,
		}
	)
end

function META:Undo()
	if not self.Editable then return end

	self._text_panel.text.editor:Undo()
	self:sync_text_changed()
end

function META:Redo()
	if not self.Editable then return end

	self._text_panel.text.editor:Redo()
	self:sync_text_changed()
end

function META:Cut()
	if not self.Editable then return end

	self._text_panel.text.editor:Cut()
	self:sync_text_changed()
end

function META:Copy()
	self._text_panel.text.editor:Copy()
end

function META:Paste()
	if not self.Editable then return end

	local editor = self._text_panel.text.editor
	local str = editor:GetClipboard()

	if str then editor:Paste(str) end

	self:sync_text_changed()
end

function META:SelectAll()
	self._text_panel.text.editor:SelectAll()
	self:sync_text_changed()
end

function META:CommitHistory()
	self.History:Add(self:GetText())
end

function META:GetText()
	return self._text_panel.text:GetText()
end

function META:GetTextPanel()
	return self._text_panel
end

function META:SetText(value)
	value = value or ""
	self.Text = value

	if not self._text_panel then return self end

	if self._search then self:end_history_search(false) end

	local editor = self._text_panel.text.editor
	self._text_panel.text:SetText(value)
	self._last_text = value
	editor.undo:Reset(value, editor.Cursor)

	if self.Autocomplete then
		self.Autocomplete:SetText(value, self._text_panel.text.editor.Cursor)
	end

	self:sync_text_changed()
	return self
end

function META:ScrollToBottom()
	self._scroll_panel:ScrollRectIntoView(0, 1e6, 0, 1e6)
end

function META:scroll_caret_into_view()
	local editor = self._text_panel.text.editor

	if not editor then return end

	local text = self._text_panel.text
	local cursor = editor.Cursor
	local line, col = text:GetLineColFromIndex(cursor)
	local font = text:GetFont()
	local lx, ly = text:GetTextOffset()
	local line_height = font:GetLineHeight()
	local vertical_step = line_height + font:GetSpacing()
	local display_lines = text.wrap_layout_info and text.wrap_layout_info.display_lines
	local display_line = display_lines and display_lines[line]
	local line_text = text.wrap_layout_info and text.wrap_layout_info.lines[line] or ""
	local cw

	if display_line and display_line.positions then
		local max_col = #display_line.positions
		local clamped = math.max(1, math.min(col, max_col))
		cw = display_line.positions[clamped] or 0
	else
		cw = font:GetTextSize(utf8.sub(line_text, 1, col - 1))
	end

	local caret_x = lx + cw
	local caret_y_top = ly + (line - 1) * vertical_step
	local caret_y_bottom = (ly + (line + 1) * vertical_step)
	self._scroll_panel:ScrollRectIntoView(caret_x, caret_y_top, caret_x, caret_y_bottom, theme.active:GetSize("XXS"))
end

function META:RequestTextFocus()
	self._text_panel:RequestFocus()
	return true
end

function META:RequestTextUnFocus()
	self._text_panel:RequestUnFocus()
	return true
end

return META:Register()
