local Vec2 = import("goluwa/structs/vec2.lua")
local system = import("goluwa/system.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local utf8 = import("goluwa/string/utf8.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
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
META:EndStorable()

function META.OnTextChanged(text_edit, text, old_text) end

function META.OnKeyInput(text_edit, key, press) end

function META.OnKeyInputRepeat(text_edit, key) end

local function on_text_focus(text)
	text.mouse_input:SetRequestMouse(true)
end

local function on_text_unfocus(text)
	text.mouse_input:SetRequestMouse(false)
end

local function on_text_cursor_moved(text)
	text.TextEdit:sync_text_changed()
end

local function on_text_key_input(text, key, press)
	return text.TextEdit.OnKeyInput(text.TextEdit, key, press)
end

local function on_text_key_input_repeat(text, key)
	return text.TextEdit.OnKeyInputRepeat(text.TextEdit, key)
end

local function forward_mouse_input(surface, button, press)
	local text_panel = surface.TextEdit._text_panel
	local mouse_pos = system.GetWindow():GetMousePosition()
	return text_panel.text:OnMouseInput(button, press, text_panel.transform:GlobalToLocal(mouse_pos))
end

function META:OnCreate(props)
	local size = props.Size or Vec2(400, theme.active:GetInputHeight(props.FontSize or "M"))
	props.Size = size
	props.MinSize = props.MinSize or Vec2(100, size.y)
	props.MaxSize = props.MaxSize or Vec2(0, size.y)
	META.BaseClass.OnCreate(self, props)
	self._single_line_height = props.MinSize.y
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
		Padding = self.Padding or Rect() + theme.active:GetPadding("S"),
		layout = {
			GrowWidth = 1,
			GrowHeight = 1,
		},
	}
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

		if lines then
			local line_count = math.clamp(#lines, 1, self.MaxLines)
			local w = self.layout:GetMinSize().x
			local h = math.ceil(self._single_line_height + (line_count - 1) * vertical_step)
			self.layout:SetMinSize(Vec2(w, h))
			self.layout:SetMaxSize(Vec2(w, h))
		end
	end

	if self.AutoScrollToCaret then
		self._scroll_panel:update_dirty_layout(self._scroll_panel)
		self:scroll_caret_into_view()
	end

	local next_text = self._text_panel.text:GetText()

	if next_text == self._last_text then return end

	local old_text = self._last_text
	self._last_text = next_text
	self.OnTextChanged(self, next_text, old_text)
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

	self._text_panel.text:SetText(value)
	self._last_text = value
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
