local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local system = import("goluwa/system.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
return function(props)
	props = props or {}
	local external_ref = props.Ref
	local wrap = props.Wrap == true
	local scroll_x = props.ScrollX
	local scroll_y = props.ScrollY

	if scroll_x == nil then scroll_x = not wrap end

	if scroll_y == nil then scroll_y = false end

	local size = props.Size or Vec2(400, 34)
	local min_size = props.MinSize or Vec2(100, size.y)
	local max_size = props.MaxSize or Vec2(0, size.y)
	local editable = props.Editable ~= false
	local panel_color = props.PanelColor or "surface_alt"
	local background_color = props.BackgroundColor or "surface"
	local text_panel
	local scroll_panel
	local last_text = props.Text or ""

	local function sync_text_changed(panel)
		if not props.OnTextChanged then return end

		local next_text = text_panel and text_panel.text and text_panel.text:GetText() or ""

		if next_text == last_text then return end

		local old_text = last_text
		last_text = next_text
		props.OnTextChanged(panel, next_text, old_text, panel)
	end

	local panel = Panel.New{
		Name = "text_edit",
		Tooltip = props.Tooltip,
		TooltipOptions = props.TooltipOptions,
		Ref = function(self)
			if props.OnTextChanged then self:AddGlobalEvent("Update") end
		end,
		transform = {
			Size = size,
		},
		layout = {
			Direction = "y",
			GrowWidth = 1,
			MinSize = min_size,
			MaxSize = max_size,
			props.layout,
		},
		gui_element = {
			OnDraw = function(self)
				theme.active:Draw(self.Owner)
			end,
			OnPostDraw = function(self)
				theme.active:DrawPost(self.Owner)
			end,
		},
		mouse_input = true,
		OnUpdate = function(self)
			sync_text_changed(self)
		end,
	}{
		ScrollablePanel{
			Ref = function(self)
				scroll_panel = self
			end,
			Color = background_color,
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
				Ref = function(self)
					text_panel = self
				end,
				Text = props.Text or "",
				Cursor = editable and "text_input" or nil,
				Editable = editable,
				Wrap = wrap,
				Color = props.TextColor or "text",
				SelectionColor = props.SelectionColor or theme.active:GetColor("text_selection"),
				FontName = props.FontName,
				FontSize = props.FontSize,
				text = props.text,
				OnKeyInput = function(self, key, press)
					if props.OnKeyInput then return props.OnKeyInput(self, key, press) end
				end,
				OnFocus = function(self, ...)
					self.mouse_input:SetRequestMouse(true)
				end,
				OnUnfocus = function(self, ...)
					self.mouse_input:SetRequestMouse(false)
				end,
				layout = {
					GrowWidth = 1,
					FitWidth = false,
					MinSize = Vec2(1, 0),
				},
			},
		},
	}
	panel:SetState("panel_color", panel_color)
	panel:SetState("editable", editable)

	function panel:GetText()
		return text_panel and text_panel.text:GetText() or ""
	end

	function panel:GetTextPanel()
		return text_panel
	end

	function panel:SetText(value)
		value = value or ""

		if text_panel and text_panel.text then text_panel.text:SetText(value) end

		last_text = value
		return self
	end

	function panel:ScrollToBottom()
		scroll_panel:ScrollRectIntoView(0, 1e6, 0, 1e6)
	end

	function panel:ScrollCaretIntoView()
		if not text_panel or not text_panel:IsValid() then return end

		local text = text_panel.text

		if not text or not text.editor then return end

		local cursor = text.editor.Cursor
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
		local caret_y = ly + (line - 1) * vertical_step
		scroll_panel:ScrollRectIntoView(caret_x, caret_y, caret_x, caret_y + line_height)
	end

	function panel:RequestTextFocus()
		if text_panel and text_panel:IsValid() then
			text_panel:RequestFocus()
			return true
		end

		return false
	end

	function panel:RequestTextUnFocus()
		if text_panel and text_panel:IsValid() then
			text_panel:RequestUnFocus()
			return true
		end

		return false
	end

	if external_ref then external_ref(panel) end

	return panel
end
