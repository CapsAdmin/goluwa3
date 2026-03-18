local prototype = import("goluwa/prototype.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local system = import("goluwa/system.lua")
local clipboard = import("goluwa/bindings/clipboard.lua")
local META = prototype.CreateTemplate("tui_text")
META:StartStorable()
META:GetSet("Text", "", {callback = "OnTextChanged"})
META:GetSet("TabSize", 4)
META:GetSet("Align", "left")
META:GetSet("Editable", false)
META:GetSet("ShowLinePrefix", false)
META:GetSet("ShowScrollbar", true)
META:EndStorable()

local function expand_tabs(s, tab_size)
	tab_size = tab_size or 4
	local res = ""
	local col = 0

	for char in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		if char == "\t" then
			local spaces = tab_size - (col % tab_size)
			res = res .. string.rep(" ", spaces)
			col = col + spaces
		else
			res = res .. char
			col = col + 1
		end
	end

	return res, col
end

local function visual_width(s, tab_size)
	local _, w = expand_tabs(s, tab_size or 4)
	return w
end

local function render_text(term, x, y, text, max_w, max_h, tab_size)
	if not text or text == "" then return end

	tab_size = tab_size or 4
	local line_offset = 0
	local is_in_code_block = false

	for _, line in ipairs(text:split("\n")) do
		if max_h and line_offset >= max_h then break end

		if line:match("^```") then
			is_in_code_block = not is_in_code_block
		else
			local expanded = expand_tabs(line, tab_size)
			local current_chunk = expanded
			local sub_line_idx = 0

			while #current_chunk > 0 do
				if max_h and line_offset >= max_h then break end

				local screen_y = y + line_offset
				term:SetCaretPosition(x, screen_y)
				local chunk_w = max_w or #current_chunk
				local chunk = current_chunk:sub(1, chunk_w)
				current_chunk = current_chunk:sub(chunk_w + 1)

				if is_in_code_block then
					term:PushForegroundColor(220, 220, 220)
					term:WriteText(chunk)
					term:PopAttribute()
				else
					local i = 1
					local is_bold, is_italic = false, false

					while i <= #chunk do
						local byte = chunk:byte(i)
						local char_len

						if byte < 0x80 then
							char_len = 1
						elseif byte < 0xE0 then
							char_len = 2
						elseif byte < 0xF0 then
							char_len = 3
						else
							char_len = 4
						end

						local char = chunk:sub(i, i + char_len - 1)
						local next_char = chunk:sub(i + 1, i + 1)

						if char == "*" and next_char == "*" then
							is_bold = not is_bold

							if is_bold then
								term:PushBold()
							else
								term:PopAttribute()
							end

							i = i + 2
						elseif char == "_" and next_char == "_" then
							is_italic = not is_italic

							if is_italic then
								term:PushItalic()
							else
								term:PopAttribute()
							end

							i = i + 2
						elseif char == "-" and sub_line_idx == 0 and i == 1 and next_char == " " then
							term:WriteText("•")
							i = i + 1
						else
							term:WriteText(char)
							i = i + char_len
						end
					end

					if is_bold then term:PopAttribute() end

					if is_italic then term:PopAttribute() end
				end

				line_offset = line_offset + 1
				sub_line_idx = sub_line_idx + 1
			end
		end
	end
end

local function draw_scrollbar(term, x, y, h, total_h, scroll_offset)
	if total_h <= h then return end

	term:PushForegroundColor(150, 150, 150)

	for i = 0, h - 1 do
		term:SetCaretPosition(x, y + i)
		term:WriteText("░")
	end

	local bar_h = math.max(1, math.floor(h * (h / total_h)))
	local max_scroll = math.max(1, total_h - h)
	local fraction = scroll_offset / max_scroll
	local bar_y = y + math.floor((h - bar_h) * fraction)

	for i = 0, bar_h - 1 do
		term:SetCaretPosition(x, bar_y + i)
		term:WriteText("█")
	end

	term:PopAttribute()
end

local function setup_clipboard(self)
	self.readonly_click_active = false
	self.Owner:EnsureComponent("tui_mouse_input")
	self.Owner.tui_mouse_input:SetFocusOnClick(true)

	self.Owner:AddLocalListener("OnMouseInput", function(_, button, press)
		if self:GetEditable() then return end

		if button ~= "left" then return end

		local text = self:GetText()

		if not text or text == "" then
			self.readonly_click_active = false
			return
		end

		if press then
			self.readonly_click_active = true
			clipboard.Set(text)
		else
			self.readonly_click_active = false
		end

		return true
	end)
end

function META:_SetupEditor()
	if self.Editor then return end

	local sequence_editor = import("goluwa/sequence_editor.lua")
	self.Editor = sequence_editor.New()
	self.Editor:SetText(self.Text or "")
	self._last_input_time = 0
	self._last_click_time = 0
	self._click_count = 0
	self._is_selecting = false
	self.Owner:EnsureComponent("tui_key_input")
	self.Owner:EnsureComponent("tui_mouse_input")
	self.Owner.tui_mouse_input:SetFocusOnClick(true)

	self.Owner:AddLocalListener("OnKeyInput", function(_, key, press, modifiers)
		if not self:GetEditable() then return end

		if not press then return end

		self._last_input_time = system.GetTime()
		self.Editor:SetShiftDown(modifiers and modifiers.shift or false)
		self.Editor:SetControlDown(modifiers and modifiers.ctrl or false)
		return self.Editor:OnKeyInput(key)
	end)

	self.Owner:AddLocalListener("OnCharInput", function(_, char)
		if not self:GetEditable() then return end

		self._last_input_time = system.GetTime()
		return self.Editor:OnCharInput(char)
	end)

	local function get_world_rect()
		local x1, y1, x2, y2 = self.Owner.transform:GetWorldRectFast()
		return math.floor(x1 + 0.5),
		math.floor(y1 + 0.5),
		math.floor(x2 - x1 + 0.5),
		math.floor(y2 - y1 + 0.5)
	end

	self.Owner:AddLocalListener("OnMouseInput", function(_, button, press, mx, my)
		if not self:GetEditable() then return end

		local ax, ay, aw, ah = get_world_rect()
		local input_lines = self.Editor.Buffer:GetLines()
		local num_lines = #input_lines
		local visible_end = math.min(num_lines, (self.Editor.ScrollOffset or 0) + ah)
		local line_index = visible_end - (ay + ah - 1 - my)
		local prefix_w = self:GetShowLinePrefix() and 2 or 0
		local target_vcol = mx - ax - prefix_w
		local time = system.GetTime()

		if button == "left" then
			if press then
				if input_lines[line_index] then
					if time - self._last_click_time < 0.3 then
						self._click_count = self._click_count + 1
					else
						self._click_count = 1
					end

					self._last_click_time = time
					self.Editor:SetSelectionStart(nil)
					self.Editor:SetVisualLineCol(line_index, target_vcol)

					if self._click_count == 2 then
						self.Editor:SelectWord()
						self._is_selecting = false
					elseif self._click_count >= 3 then
						self.Editor:SelectLine()
						self._is_selecting = false
					else
						self.Editor:SetSelectionStart(self.Editor:GetCursor())
						self._is_selecting = true
					end
				end
			else
				self._is_selecting = false

				if self.Editor:GetSelectionStart() == self.Editor:GetCursor() then
					self.Editor:SetSelectionStart(nil)
				end
			end
		end

		self._last_input_time = time
		return true
	end)

	local event = import("goluwa/event.lua")
	local listener_id = tostring(self)

	event.AddListener("TerminalMouseMoved", listener_id, function(mx, my)
		if not self._is_selecting then return end

		if not self.Owner:IsValid() then
			event.RemoveListener("TerminalMouseMoved", listener_id)
			return
		end

		local ax, ay, aw, ah = get_world_rect()
		local input_lines = self.Editor.Buffer:GetLines()
		local num_lines = #input_lines
		local visible_end = math.min(num_lines, (self.Editor.ScrollOffset or 0) + ah)
		local line_index = math.max(1, math.min(num_lines, visible_end - (ay + ah - 1 - my)))
		local prefix_w = self:GetShowLinePrefix() and 2 or 0
		local target_vcol = mx - ax - prefix_w

		if input_lines[line_index] then
			self.Editor:SetVisualLineCol(line_index, target_vcol)
		end
	end)

	self.Owner:AddLocalListener("OnMouseWheel", function(_, delta)
		if not self:GetEditable() then return end

		self.Editor:OnMouseWheel(-delta)
		return true
	end)
end

function META:SetEditable(val)
	self.Editable = val
	self.readonly_click_active = false

	if val then self:_SetupEditor() end
end

function META:GetEditorText()
	if self.Editor then return self.Editor:GetText() end

	return self.Text
end

function META:GetEditor()
	return self.Editor
end

function META:_DrawEditor(term, abs_x, abs_y, w, h)
	local editor = self.Editor
	local input_lines = editor.Buffer:GetLines()
	local num_lines = #input_lines
	local time = system.GetTime()
	local blink_time = time - (self._last_input_time or 0)
	local cursor_blink = math.floor(blink_time * 2) % 2 == 0
	local tab_size = self:GetTabSize()
	local show_prefix = self:GetShowLinePrefix()
	local prefix_w = show_prefix and 2 or 0
	local content_w = w - prefix_w
	editor:SetViewportHeight(h)
	editor:UpdateViewport()
	local cur_line, cur_col = editor:GetCursorLineCol()
	local visible_start = (editor.ScrollOffset or 0) + 1
	local visible_end = math.min(num_lines, (editor.ScrollOffset or 0) + h)
	local sel_start, sel_stop = editor:GetSelection()
	local current_char_idx = 1

	for i, line in ipairs(input_lines) do
		if i >= visible_start and i <= visible_end then
			local line_offset = visible_end - i
			local screen_y = abs_y + (h - 1) - line_offset
			term:SetCaretPosition(abs_x, screen_y)

			if show_prefix then
				term:PushForegroundColor(100, 180, 180)
				term:WriteText((i == 1) and "> " or "  ")
				term:PopAttribute()
			end

			if not sel_start then
				local expanded_line, _ = expand_tabs(line, tab_size)
				term:WriteText(expanded_line)
				current_char_idx = current_char_idx + #line
			else
				local col = 0

				for j = 1, #line do
					local char = line:sub(j, j)
					local is_selected = current_char_idx >= sel_start and current_char_idx < sel_stop

					if is_selected then
						term:PushBackgroundColor(150, 150, 150)
						term:PushForegroundColor(0, 0, 0)
					end

					if char == "\t" then
						local spaces = tab_size - (col % tab_size)
						term:WriteText(string.rep(" ", spaces))
						col = col + spaces
					else
						term:WriteText(char)
						col = col + 1
					end

					if is_selected then
						term:PopAttribute()
						term:PopAttribute()
					end

					current_char_idx = current_char_idx + 1
				end
			end

			if i < num_lines then
				if sel_start then
					local is_selected = current_char_idx >= sel_start and current_char_idx < sel_stop

					if is_selected then
						term:PushBackgroundColor(150, 150, 150)
						term:WriteText(" ")
						term:PopAttribute()
					end
				end

				current_char_idx = current_char_idx + 1
			end
		else
			current_char_idx = current_char_idx + #line + 1
		end
	end

	if self:GetShowScrollbar() then
		draw_scrollbar(term, abs_x + w - 1, abs_y, h, num_lines, editor.ScrollOffset or 0)
	end

	if cursor_blink and cur_line >= visible_start and cur_line <= visible_end then
		local line_offset = visible_end - cur_line
		local screen_y = abs_y + (h - 1) - line_offset
		local line_text = input_lines[cur_line]
		local _, cur_vcol = expand_tabs(line_text:sub(1, cur_col - 1), tab_size)
		term:SetCaretPosition(abs_x + prefix_w + cur_vcol, screen_y)
		term:PushBackgroundColor(255, 255, 255)
		term:PushForegroundColor(0, 0, 0)
		local char = line_text:sub(cur_col, cur_col)

		if char == "" then
			char = " "
		elseif char == "\t" then
			local spaces = tab_size - (cur_vcol % tab_size)
			char = string.rep(" ", spaces)
		end

		term:WriteText(char)
		term:PopAttribute()
		term:PopAttribute()
	end
end

function META:Initialize()
	self.Owner:EnsureComponent("tui_element")
	setup_clipboard(self)

	self.Owner:AddLocalListener("OnDraw", function(_, term, abs_x, abs_y, w, h)
		self:OnDraw(term, abs_x, abs_y, w, h)
	end)

	if self:GetEditable() then self:_SetupEditor() end

	self:OnTextChanged()
end

function META:OnTextChanged()
	if self.Editor then self.Editor:SetText(self.Text or "") end

	if not self.Owner.transform then return end

	local tw, th = self:GetTextSize()
	local height = math.max(1, th)

	if self.Owner.layout then
		local cur_min = self.Owner.layout:GetMinSize()
		self.Owner.layout:SetMinSize(Vec2(cur_min.x, height))
	else
		self.Owner.transform:SetHeight(height)
	end

	if self.Owner.layout then self.Owner.layout:InvalidateLayout() end

	if self.Owner:HasParent() and self.Owner:GetParent().layout then
		self.Owner:GetParent().layout:InvalidateLayout()
	end
end

function META:OnDraw(term, abs_x, abs_y, w, h)
	if self:GetEditable() and self.Editor then
		self:_DrawEditor(term, abs_x, abs_y, w, h)
		return
	end

	local text = self:GetText()

	if not text or text == "" then return end

	if self.readonly_click_active then
		term:PushBackgroundColor(150, 150, 150)
		term:PushForegroundColor(0, 0, 0)
	end

	render_text(
		term,
		abs_x,
		abs_y,
		text,
		w > 0 and w or nil,
		h > 0 and h or nil,
		self:GetTabSize()
	)

	if self.readonly_click_active then
		term:PopAttribute()
		term:PopAttribute()
	end
end

function META:GetTextSize(max_width)
	local text = self:GetText()

	if not text or text == "" then return 0, 0 end

	local tab_size = self:GetTabSize()
	local width = 0
	local height = 0

	for _, line in ipairs(text:split("\n")) do
		if not line:match("^```") then
			local _, total_w = expand_tabs(line, tab_size)

			if max_width and total_w > max_width then
				local lines_needed = math.ceil(total_w / max_width)
				height = height + lines_needed
				width = max_width
			else
				height = height + 1

				if total_w > width then width = total_w end
			end
		end
	end

	return width, height
end

return META:Register()
