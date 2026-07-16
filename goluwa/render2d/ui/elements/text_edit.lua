local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local utf8 = import("goluwa/string/utf8.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("text_edit")
META.Name = "text_edit"
META.CMP.transform = {
	Size = Vec2(400, 34),
}
META.CMP.layout = {
	Direction = "y",
	GrowWidth = 1,
}
META.CMP.gui_element = {
	OnDraw = function(self)
		theme.active:Draw(self.Owner)
	end,
	OnPostDraw = function(self)
		theme.active:DrawPost(self.Owner)
	end,
}
META.CMP.mouse_input = {}
META:GetSet("AutoResize", false)
META:GetSet("MaxLines", 4)

function META:OnCreate(props)
	props = props or {}
	local wrap = props.Wrap == true
	local editable = props.Editable ~= false
	local scroll_x = props.ScrollX ~= nil and props.ScrollX or not wrap
	local scroll_y = props.ScrollY == true
	local size = props.Size or Vec2(400, 34)
	local min_size = props.MinSize or Vec2(100, size.y)
	local max_size = props.MaxSize or Vec2(0, size.y)
	self.auto_scroll_to_caret = nil_fallback(props.AutoScrollToCaret, true)
	self.AutoResize = props.AutoResize == true
	self.MaxLines = props.MaxLines or 4
	self.last_text = props.Text or ""
	self.on_text_changed = props.OnTextChanged
	self.BaseClass.OnCreate(self, {Ref = props.Ref})
	self.layout:SetMinSize(min_size)
	self.layout:SetMaxSize(max_size)
	self.transform:SetSize(size)
	self:SetState("panel_color", props.PanelColor or "surface_alt")
	self:SetState("editable", editable)
	self:AddChild(
		Panel.New{
			IsInternal = true,
			Name = "scroll_panel",
			transform = {
				Size = self.transform:GetSize():Copy(),
			},
			layout = {
				MinSize = self.layout:GetMinSize():Copy(),
				MaxSize = self.layout:GetMaxSize():Copy(),
				GrowHeight = 1,
			},
		}{
			ScrollablePanel{
				Ref = function(s)
					self.scroll_panel = s
				end,
				Color = props.BackgroundColor or "surface",
				Cursor = editable and "text_input" or nil,
				ScrollX = scroll_x,
				ScrollY = scroll_y,
				ScrollBarVisible = props.ScrollBarVisible,
				ScrollBarAutoHide = props.ScrollBarAutoHide,
				ScrollBarColor = props.ScrollBarColor or "scrollbar",
				ScrollBarTrackColor = props.ScrollBarTrackColor or "scrollbar_track",
				Padding = props.Padding or Rect() + 12,
				layout = {
					GrowWidth = 1,
					GrowHeight = 1,
				},
			}{
				Text{
					Ref = function(s)
						self.text_panel = s
					end,
					Text = props.Text or "",
					Hint = props.Hint or "",
					Cursor = editable and "text_input" or nil,
					Editable = editable,
					Wrap = wrap,
					Color = props.TextColor or "text",
					SelectionColor = props.SelectionColor or theme.active:GetColor("text_selection"),
					FontName = props.FontName,
					FontSize = props.FontSize,
					text = props.text,
					OnKeyInput = function(s, key, press)
						if props.OnKeyInput then return props.OnKeyInput(s, key, press) end
					end,
					OnCursorMoved = function()
						self:sync_text_changed()
					end,
					OnFocus = function(s, ...)
						s.mouse_input:SetRequestMouse(true)
					end,
					OnUnfocus = function(s, ...)
						s.mouse_input:SetRequestMouse(false)
					end,
					layout = {
						GrowWidth = 1,
						FitWidth = false,
						MinSize = Vec2(1, 0),
					},
				},
			},
		}
	)
end

function META:OnParentVisibilityChanged(visible)
	self:sync_text_changed()
end

function META:sync_text_changed()
	if self.auto_scroll_to_caret then self:scroll_caret_into_view() end

	if self.AutoResize then
		local lines, _, vertical_step = self.text_panel.text:GetTextSize2()

		if lines then
			local line_count = math.clamp(#lines, 1, self.MaxLines)
			local w = self.layout:GetMinSize().x
			local h = (line_count + 1) * vertical_step
			self.layout:SetMinSize(Vec2(w, h))
			self.layout:SetMaxSize(Vec2(w, h))
		end
	end

	local next_text = self.text_panel.text:GetText()

	if next_text == self.last_text then return end

	local old_text = self.last_text
	self.last_text = next_text

	if self.on_text_changed then
		self.on_text_changed(self, next_text, old_text, self)
	end
end

function META:GetText()
	return self.text_panel.text:GetText()
end

function META:GetTextPanel()
	return self.text_panel
end

function META:SetText(value)
	value = value or ""
	self.text_panel.text:SetText(value)
	self.last_text = value
	self:sync_text_changed()
	return self
end

function META:scroll_to_bottom()
	self.scroll_panel:ScrollRectIntoView(0, 1e6, 0, 1e6)
end

function META:scroll_caret_into_view()
	local editor = self.text_panel.text.editor

	if not editor then return end

	local text = self.text_panel.text
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
	self.scroll_panel:ScrollRectIntoView(caret_x, caret_y_top, caret_x, caret_y_bottom, 4)
end

function META:RequestTextFocus()
	self.text_panel:RequestFocus()
	return true
end

function META:RequestTextUnFocus()
	self.text_panel:RequestUnFocus()
	return true
end

META:Register()
return META.New
