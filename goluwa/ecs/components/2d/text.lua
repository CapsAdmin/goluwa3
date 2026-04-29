local prototype = import("goluwa/prototype.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local sequence_editor = import("goluwa/sequence_editor.lua")
local pretext = import("goluwa/pretext/init.lua")
local utf8 = import("goluwa/utf8.lua")
local META = prototype.CreateTemplate("text")
META:StartStorable()
META:GetSet(
	"Font",
	fonts.New{Path = fonts.GetDefaultSystemFontPath(), Size = 14},
	{callback = "OnTextChanged"}
)
META:GetSet("FontSize", 14, {callback = "OnTextChanged"})
META:GetSet("Text", "", {callback = "OnTextChanged"})
META:GetSet("Wrap", false, {callback = "OnTextChanged"})
META:GetSet("WrapToParent", false, {callback = "OnTextChanged"})
META:GetSet("Elide", false, {callback = "OnTextChanged"})
META:GetSet("ElideString", "...", {callback = "OnTextChanged"})
META:GetSet("AlignX", "left", {callback = "OnTextChanged"})
META:GetSet("AlignY", "top", {callback = "OnTextChanged"})
META:GetSet("DisableViewportCulling", false)
META:GetSet("Color", Color(1, 1, 1, 1))
META:GetSet("SelectionColor", Color(1, 1, 1, 0.3))
META:GetSet("Editable", false, {callback = "OnEditableChanged"})
META:EndStorable()

local function count_expandable_spaces(text)
	local count = 0

	for _, char in ipairs(utf8.to_list(text)) do
		if char == " " then count = count + 1 end
	end

	return count
end

local function build_display_line(font, line_text, natural_width, target_width, justify)
	local chars = utf8.to_list(line_text)
	local positions = {0}
	local chunks = {}
	local space_count = count_expandable_spaces(line_text)
	local extra_per_space = 0
	local justified = false
	local prefix = {}
	local extra_seen = 0
	local chunk_start = nil
	local chunk_buffer = {}

	if justify and space_count > 0 and natural_width < target_width then
		extra_per_space = (target_width - natural_width) / space_count
		justified = extra_per_space > 0
	end

	local function flush_chunk(stop_col)
		if #chunk_buffer == 0 or not chunk_start then return end

		chunks[#chunks + 1] = {
			text = table.concat(chunk_buffer),
			x = positions[chunk_start] or 0,
			start_col = chunk_start,
			stop_col = stop_col,
		}

		for i = #chunk_buffer, 1, -1 do
			chunk_buffer[i] = nil
		end

		chunk_start = nil
	end

	for i, char in ipairs(chars) do
		if char ~= " " then
			if not chunk_start then chunk_start = i end

			chunk_buffer[#chunk_buffer + 1] = char
		else
			flush_chunk(i)
			extra_seen = extra_seen + 1
		end

		prefix[#prefix + 1] = char
		positions[i + 1] = font:GetTextSize(table.concat(prefix)) + extra_per_space * extra_seen
	end

	flush_chunk(#chars + 1)
	return {
		text = line_text,
		positions = positions,
		chunks = chunks,
		natural_width = natural_width,
		width = positions[#chars + 1] or natural_width,
		extra_per_space = extra_per_space,
		justified = justified,
	}
end

local function get_line_column_offset(font, line_text, col, display_line)
	if display_line and display_line.positions then
		local max_col = #display_line.positions
		local clamped = math.max(1, math.min(col, max_col))
		return display_line.positions[clamped] or 0
	end

	return font:GetTextSize(utf8.sub(line_text, 1, col - 1))
end

local function get_wrap_width(self, available_width)
	local width = self.Owner.transform.Size.x

	if available_width and available_width > 1 then
		width = available_width
	elseif
		self:GetWrapToParent() and
		self.Owner:GetParent() and
		self.Owner:GetParent().transform
	then
		width = self.Owner:GetParent().transform.Size.x
	end

	if self.Owner.layout then
		local p = self.Owner.layout:GetPadding()
		width = width - p.x - p.w
	end

	return width
end

local function get_elide_width(self, available_width)
	local width = self.Owner.transform.Size.x

	if available_width and available_width > 0 then width = available_width end

	if self.Owner.layout then
		local p = self.Owner.layout:GetPadding()
		width = width - p.x - p.w
	end

	return math.max(0, width)
end

local function build_elided_text(self, font, text, available_width)
	local max_width = get_elide_width(self, available_width)

	if max_width <= 0 then return "" end

	local full_width = select(1, font:GetTextSize(text))

	if full_width <= max_width then return text end

	local elide = self:GetElideString() or "..."
	local elide_width = select(1, font:GetTextSize(elide))

	if elide_width >= max_width then return "" end

	local chars = utf8.to_list(text)
	local out = {}
	local current_width = 0

	for i, char in ipairs(chars) do
		local char_width = select(1, font:GetTextSize(char))

		if current_width + char_width + elide_width > max_width then break end

		out[#out + 1] = char
		current_width = current_width + char_width
	end

	if #out == 0 then return elide_width <= max_width and elide or "" end

	return table.concat(out) .. elide
end

local function get_wrap_options(self)
	if self:GetEditable() then return {white_space = "pre-wrap"} end

	return nil
end

local function build_wrap_layout(self, font, text, width)
	local prepared = pretext.prepare(text, font, get_wrap_options(self))
	local line_height = font:GetLineHeight()
	local layout = pretext.layout_with_lines(prepared, width, line_height)
	local raw_length = utf8.length(text)
	local lines = {}
	local ranges = {}
	local display_lines = {}
	local justify = self:GetAlignX() == "justify"
	local measured_width = 0

	if #layout.lines == 0 then
		lines[1] = ""
		ranges[1] = {text = "", start = 1, stop = raw_length + 1, width = 0}
		display_lines[1] = build_display_line(font, "", 0, width, false)
	else
		for i, line in ipairs(layout.lines) do
			lines[i] = line.text
			local start_index = pretext.cursor_to_text_index(prepared, line.start)
			local stop_index = raw_length + 1

			if layout.lines[i + 1] then
				stop_index = pretext.cursor_to_text_index(prepared, layout.lines[i + 1].start)
			end

			local ends_paragraph = stop_index > 1 and utf8.sub(text, stop_index - 1, stop_index - 1) == "\n"
			local should_justify = justify and i < #layout.lines and not ends_paragraph
			local display_line = build_display_line(font, line.text, line.width, width, should_justify)
			display_lines[i] = display_line
			measured_width = math.max(measured_width, line.width)
			ranges[i] = {
				text = line.text,
				start = start_index,
				stop = stop_index,
				width = line.width,
				display_width = display_line.width,
				justified = display_line.justified,
			}
		end
	end

	return {
		prepared = prepared,
		layout = layout,
		lines = lines,
		ranges = ranges,
		display_lines = display_lines,
		text = table.concat(lines, "\n"),
		raw_length = raw_length,
		line_height = line_height,
		width = width,
		measured_width = measured_width,
		measured_height = math.max(layout.height or 0, math.max(1, #lines) * line_height),
		font = font,
		source_text = text,
	}
end

local function get_cached_wrap_layout(self, width)
	local font = self:GetFont() or fonts.GetDefaultFont()
	local text = self:GetText()
	local wrapped_width = get_wrap_width(self, width)
	local layout = self.wrap_layout_info

	if
		layout and
		layout.width == wrapped_width and
		layout.font == font and
		layout.source_text == text
	then
		return layout
	end

	layout = self.measure_wrap_layout_info

	if
		layout and
		layout.width == wrapped_width and
		layout.font == font and
		layout.source_text == text
	then
		return layout
	end

	layout = build_wrap_layout(self, font, text, wrapped_width)
	self.measure_wrap_layout_info = layout
	return layout
end

function META:OnEditableChanged()
	if self:GetEditable() then
		if not self.Owner:HasComponent("key_input") then
			self.Owner:AddComponent("key_input")
		end

		if self.Owner.mouse_input then self.Owner.mouse_input:SetFocusOnClick(true) end

		if not self.editor then
			self.editor = sequence_editor.New(self:GetText())
			self.editor.OnTextChanged = function(_, text)
				self._is_updating_from_editor = true
				self:SetText(text)
				self._is_updating_from_editor = false
			end
			self.editor.OnMoveUp = function(editor)
				if not self:MoveCaretVertical(-1) then
					local line, col = editor:GetVisualLineCol()
					editor.PreferredVCol = editor.PreferredVCol or col

					if line > 1 then editor:SetVisualLineCol(line - 1, editor.PreferredVCol) end
				end
			end
			self.editor.OnMoveDown = function(editor)
				if not self:MoveCaretVertical(1) then
					local line, col = editor:GetVisualLineCol()
					editor.PreferredVCol = editor.PreferredVCol or col
					local line_count = editor:GetVisualLineCount()

					if line < line_count then
						editor:SetVisualLineCol(line + 1, editor.PreferredVCol)
					end
				end
			end
			self.editor.OnPageUp = function(editor)
				if not self:MoveCaretVertical(-10) then
					local line, col = editor:GetVisualLineCol()
					editor.PreferredVCol = editor.PreferredVCol or col
					editor:SetVisualLineCol(math.max(1, line - 10), editor.PreferredVCol)
				end
			end
			self.editor.OnPageDown = function(editor)
				if not self:MoveCaretVertical(10) then
					local line, col = editor:GetVisualLineCol()
					editor.PreferredVCol = editor.PreferredVCol or col
					local line_count = editor:GetVisualLineCount()
					editor:SetVisualLineCol(math.min(line_count, line + 10), editor.PreferredVCol)
				end
			end
		end
	end
end

function META:Initialize()
	self.Owner:EnsureComponent("gui_element")
	self.Owner:EnsureComponent("transform")
	self:OnEditableChanged()
	self:OnTextChanged()

	event.AddListener("OnFontsChanged", self, function(font)
		if font == self:GetFont() or true then self:OnTextChanged() end
	end)

	self.Owner:AddLocalListener(
		"OnKeyInput",
		function(pnl, key, press)
			if self:GetEditable() and self.editor and prototype.GetFocusedObject() == self.Owner then
				if key == "left_shift" or key == "right_shift" then
					self.editor:SetShiftDown(press)
				elseif key == "left_control" or key == "right_control" then
					self.editor:SetControlDown(press)
				end

				if press then
					if key ~= "up" and key ~= "down" and key ~= "pageup" and key ~= "pagedown" then
						self.preferred_caret_x = nil
					end

					self.editor:OnKeyInput(key)
					self:ResetCaretBlink()
				end
			end
		end,
		"text_edit"
	)

	self.Owner:AddLocalListener(
		"OnCharInput",
		function(pnl, char)
			if char:byte() < 32 then return end

			if char:byte() == 127 then return end

			if self:GetEditable() and self.editor and prototype.GetFocusedObject() == self.Owner then
				self.preferred_caret_x = nil
				self.editor:OnCharInput(char)
				self:ResetCaretBlink()
			end
		end,
		"text_edit"
	)

	self.Owner:AddLocalListener(
		"OnGlobalMouseMove",
		function(pnl, pos)
			if self.dragging and self.editor then
				local local_pos = self.Owner.transform:GlobalToLocal(pos)
				local index = self:GetIndexAtPosition(local_pos.x, local_pos.y)
				self.preferred_caret_x = nil
				self.editor:SetCursor(index)
				self:ResetCaretBlink()
			end
		end,
		"text_selection"
	)

	self.Owner:AddLocalListener(
		"OnGlobalMouseInput",
		function(pnl, button, press, pos)
			if button == "button_1" and not press then
				self.dragging = false

				if self.editor and self.editor.Cursor == self.editor.SelectionStart then
					self.editor:SetSelectionStart(nil)
				end
			end
		end,
		"text_selection"
	)

	self.Owner:AddLocalListener("OnTransformChanged", function()
		if self:GetWrap() then
			local width = get_wrap_width(self)

			if self.last_wrap_width ~= width then
				self.last_wrap_width = width
				self:OnTextChanged()
			end
		elseif self:GetElide() then
			local width = get_elide_width(self)

			if self.last_elide_width ~= width then
				self.last_elide_width = width
				self:OnTextChanged()
			end
		end
	end)
end

function META:OnRemove()
	event.RemoveListener("OnFontsChanged", self)
end

function META:GetTextSize()
	if self:GetWrap() and self.wrap_layout_info then
		return self.wrap_layout_info.measured_width,
		self.wrap_layout_info.measured_height
	end

	local font = self:GetFont() or fonts.GetDefaultFont()
	return font:GetTextSize(self.draw_text or self.wrapped_text or self:GetText())
end

function META:Measure(available_width, available_height)
	local font = self:GetFont() or fonts.GetDefaultFont()
	local text = self:GetText()

	if self:GetWrap() then
		local layout = get_cached_wrap_layout(self, available_width)
		local w = layout.measured_width
		local h = layout.measured_height

		if self.Owner.layout then
			local p = self.Owner.layout:GetPadding()
			w = w + p.x + p.w
			h = h + p.y + p.h
		end

		return w, h
	end

	if self:GetElide() then
		local draw_text = build_elided_text(self, font, text, available_width)
		local w, h = font:GetTextSize(draw_text)

		if self.Owner.layout then
			local p = self.Owner.layout:GetPadding()
			w = w + p.x + p.w
			h = h + p.y + p.h
		end

		return w, h
	end

	local w, h = font:GetTextSize(text)

	if self.Owner.layout then
		local p = self.Owner.layout:GetPadding()
		w = w + p.x + p.w
		h = h + p.y + p.h
	end

	return w, h
end

function META:OnTextChanged()
	if not self.Owner.transform then return end -- not ready yet
	local font = self:GetFont() or fonts.GetDefaultFont()
	local text = self:GetText()
	self.measure_wrap_layout_info = nil

	if self.editor and not self._is_updating_from_editor then
		if self.editor:GetText() ~= text then self.editor:SetText(text) end
	end

	self.preferred_caret_x = nil

	if self:GetWrap() then
		local width = get_wrap_width(self)
		self.wrap_layout_info = build_wrap_layout(self, font, text, width)
		self.measure_wrap_layout_info = self.wrap_layout_info
		self.wrapped_text = self.wrap_layout_info.text
		self.draw_text = self.wrapped_text
		self.last_elide_width = nil
	elseif self:GetElide() then
		self.wrap_layout_info = nil
		self.wrapped_text = text
		self.last_elide_width = get_elide_width(self)
		self.draw_text = build_elided_text(self, font, text)
	else
		self.wrap_layout_info = nil
		self.wrapped_text = text
		self.draw_text = text
		self.last_elide_width = nil
	end

	local w, h

	if self:GetWrap() then
		w = self.wrap_layout_info.measured_width
		h = self.wrap_layout_info.measured_height
	else
		w, h = font:GetTextSize(self.draw_text or text)
	end

	if not self:GetWrap() and not self:GetElide() then
		self.Owner.transform:SetSize(Vec2(w, h))
	else
		-- When wrapping, we update our height to match the text
		-- but we don't want to shrink our width to the tight bounding box
		-- as that causes feedback loops with layouts that FitWidth.
		self.Owner.transform:SetHeight(h)
	end

	if self.Owner.layout then self.Owner.layout:InvalidateLayout() end
end

function META:GetWrappedSize(width)
	if self:GetWrap() then
		local layout = get_cached_wrap_layout(self, width)
		return Vec2(layout.measured_width, layout.measured_height)
	end

	local font = self:GetFont() or fonts.GetDefaultFont()
	local text = self:GetText()
	local w, h = font:GetTextSize(text)
	return Vec2(w, h)
end

function META:ResetCaretBlink()
	self.caret_blink_reset_time = system.GetElapsedTime()
end

function META:IsCaretVisible()
	return (
			(
				system.GetElapsedTime() - (
					self.caret_blink_reset_time or
					0
				)
			) * 2
		) % 2 < 1
end

function META:GetVisibleTextLines(text, font, lx, ly, clip_y1, clip_y2)
	local lines = text

	if type(lines) == "string" then lines = lines:split("\n", true) end

	if not lines or #lines == 0 then lines = {""} end

	local line_height = font:GetLineHeight()
	local vertical_step = line_height + font:GetSpacing()
	local first = 1
	local last = #lines

	if vertical_step > 0 then
		first = math.max(1, math.floor((clip_y1 - ly) / vertical_step) + 1)
		last = math.min(#lines, math.floor((clip_y2 - ly) / vertical_step) + 1)
	end

	return lines, line_height, vertical_step, first, last
end

function META:OnDraw()
	local transform = self.Owner.transform
	local font = self:GetFont() or fonts.GetDefaultFont()
	local text = self.wrapped_text or self:GetText()
	local lx, ly = self:GetTextOffset()
	local tw, th = self:GetTextSize()
	local descent = font:GetDescent()
	local is_focused_editable = self:GetEditable() and self.editor and prototype.GetFocusedObject() == self.Owner
	local line_height = font:GetLineHeight()

	if self.wrap_layout_info and self:GetAlignX() == "justify" then
		tw = math.max(tw, self.wrap_layout_info.width or 0)
	end

	if is_focused_editable then
		th = math.max(th, line_height)
		tw = math.max(tw, 2)
	end

	local clip_x1, clip_y1, clip_x2, clip_y2

	if self:GetDisableViewportCulling() then
		clip_x1 = lx
		clip_y1 = ly
		clip_x2 = lx + tw
		clip_y2 = ly + th + descent
	else
		clip_x1, clip_y1, clip_x2, clip_y2 = transform:GetVisibleLocalRect(lx, ly, tw, th + descent)
	end

	if clip_x1 == nil then return end

	local source_lines = self.wrap_layout_info and self.wrap_layout_info.lines or text
	local lines, line_height, vertical_step, visible_start, visible_stop = self:GetVisibleTextLines(source_lines, font, lx, ly, clip_y1, clip_y2)

	if is_focused_editable then
		local start, stop = self.editor:GetSelection()

		if start and start ~= stop then
			local line_start, col_start = self:GetLineColFromIndex(start)
			local line_stop, col_stop = self:GetLineColFromIndex(stop)
			local r, g, b, a = self:GetSelectionColor():Unpack()
			render2d.SetColor(r, g, b)
			render2d.SetAlphaMultiplier(a)
			render2d.SetTexture(nil)
			render2d.PushBorderRadius(2)

			for i = math.max(line_start, visible_start), math.min(line_stop, visible_stop) do
				local line_text = lines[i] or ""
				local c_start = (i == line_start) and col_start or 1
				local c_stop = (i == line_stop) and col_stop or utf8.length(line_text) + 1
				local display_line = self.wrap_layout_info and
					self.wrap_layout_info.display_lines and
					self.wrap_layout_info.display_lines[i]
				local x_offset = get_line_column_offset(font, line_text, c_start, display_line)
				local width = get_line_column_offset(font, line_text, c_stop, display_line) - x_offset

				if i < line_stop then width = math.max(width, 5) end

				render2d.DrawRect(lx + x_offset, ly - descent / 2 + (i - 1) * vertical_step, width, line_height)
			end

			render2d.PopBorderRadius()
			render2d.SetAlphaMultiplier(1)
		end
	end

	render2d.SetTexture(nil)
	local c = self.Owner:CallLocalEvent("OnGetTextColor")

	if not c then c = self:GetColor() end

	render2d.SetColor(c.r, c.g, c.b)
	render2d.SetAlphaMultiplier(c.a)

	for i = visible_start, visible_stop do
		local y = ly + (i - 1) * vertical_step
		local display_line = self.wrap_layout_info and
			self.wrap_layout_info.display_lines and
			self.wrap_layout_info.display_lines[i]

		if display_line and display_line.justified then
			font:DrawText(lines[i] or "", lx, y, 0, nil, nil, display_line.extra_per_space)
		else
			font:DrawText(lines[i] or "", lx, y, 0)
		end
	end

	if is_focused_editable and self:IsCaretVisible() then
		local cursor = self.editor.Cursor
		local found_line, found_col = self:GetLineColFromIndex(cursor)

		if found_line >= visible_start and found_line <= visible_stop then
			local line_text = lines[found_line] or ""
			local display_line = self.wrap_layout_info and
				self.wrap_layout_info.display_lines and
				self.wrap_layout_info.display_lines[found_line]
			local cw = get_line_column_offset(font, line_text, found_col, display_line)
			render2d.PushBorderRadius(2)
			render2d.DrawRect(lx + cw, ly - descent / 2 + (found_line - 1) * vertical_step, 2, line_height)
			render2d.PopBorderRadius()
		end
	end
end

function META:GetTextOffset()
	local font = self:GetFont() or fonts.GetDefaultFont()
	local text = self.draw_text or self.wrapped_text or self:GetText()
	local size = self.Owner.transform.Size
	local ax, ay = self:GetAlignX(), self:GetAlignY()
	local left, top, right, bottom = 0, 0, 0, 0

	if self.Owner.layout then
		local p = self.Owner.layout:GetPadding()
		left, top, right, bottom = p.x, p.y, p.w, p.h
	end

	local content_size = Vec2(size.x - left - right, size.y - top - bottom)
	local x, y = left, top

	if type(ax) == "number" then
		x = left + content_size.x * ax
	elseif ax == "center" then
		x = left + content_size.x / 2
	elseif ax == "right" then
		x = left + content_size.x
	end

	if type(ay) == "number" then
		y = top + content_size.y * ay
	elseif ay == "center" then
		y = top + content_size.y / 2
	elseif ay == "bottom" then
		y = top + content_size.y
	elseif ay == "baseline" then
		y = top
	end

	local tw, th = font:GetTextSize(text)

	if self.wrap_layout_info and ax == "justify" then
		tw = math.max(tw, self.wrap_layout_info.width or 0)
	end

	local lx, ly = x, y

	if type(ax) == "number" then
		lx = x - tw * ax
	elseif ax == "center" then
		lx = x - tw / 2
	elseif ax == "right" then
		lx = x - tw
	end

	if type(ay) == "number" then
		ly = y - th * ay
	elseif ay == "center" then
		ly = y - th / 2
	elseif ay == "bottom" then
		ly = y - th
	elseif ay == "baseline" then
		ly = y - font:GetAscent()
	end

	return lx, ly
end

function META:MoveCaretVertical(delta)
	if not (self:GetWrap() and self.wrap_layout_info and self.editor) then
		return false
	end

	local font = self:GetFont() or fonts.GetDefaultFont()
	local line, col = self:GetLineColFromIndex(self.editor.Cursor)
	local lx, ly = self:GetTextOffset()
	local line_height = font:GetLineHeight()
	local vertical_step = line_height + font:GetSpacing()
	local line_text = self.wrap_layout_info.lines[line] or ""
	local display_line = self.wrap_layout_info.display_lines and self.wrap_layout_info.display_lines[line]
	local preferred_x = self.preferred_caret_x or
		(
			lx + get_line_column_offset(font, line_text, col, display_line)
		)
	local target_line = math.max(1, math.min(#self.wrap_layout_info.lines, line + delta))
	local target_y = ly + (target_line - 1) * vertical_step + line_height * 0.5
	local index = self:GetIndexAtPosition(preferred_x, target_y)
	self.editor:SetCursor(index)
	self.preferred_caret_x = preferred_x
	return true
end

function META:GetIndexAtPosition(mx, my)
	if self:GetWrap() and self.wrap_layout_info then
		local font = self:GetFont() or fonts.GetDefaultFont()
		local lx, ly = self:GetTextOffset()
		local rx, ry = mx - lx, my - ly
		local line_height = font:GetLineHeight()
		local vertical_step = line_height + font:GetSpacing()
		local ranges = self.wrap_layout_info.ranges
		local line_idx = math.floor(ry / vertical_step) + 1

		if line_idx < 1 then
			line_idx = 1
			rx = -1e9
		end

		if line_idx > #ranges then
			line_idx = #ranges
			rx = 1e9
		end

		local line_text = ranges[line_idx] and ranges[line_idx].text or ""
		local display_line = self.wrap_layout_info.display_lines and
			self.wrap_layout_info.display_lines[line_idx]
		local char_idx_in_line = utf8.length(line_text) + 1

		if display_line and display_line.positions then
			for i = 1, #display_line.positions - 1 do
				local mid = (display_line.positions[i] + display_line.positions[i + 1]) * 0.5

				if rx < mid then
					char_idx_in_line = i

					break
				end
			end
		else
			local cumulative_w = 0

			for i, char in ipairs(utf8.to_list(line_text)) do
				local cw = font:GetTextSize(char)

				if rx < cumulative_w + cw / 2 then
					char_idx_in_line = i

					break
				end

				cumulative_w = cumulative_w + cw
				char_idx_in_line = i + 1
			end
		end

		local line_range = ranges[line_idx]
		local max_index = line_range.start + utf8.length(line_text)
		return math.min(line_range.start + char_idx_in_line - 1, max_index)
	end

	local font = self:GetFont() or fonts.GetDefaultFont()
	local text = self.wrapped_text or self:GetText()
	local lx, ly = self:GetTextOffset()
	local rx, ry = mx - lx, my - ly
	local line_height = font:GetLineHeight()
	local vertical_step = line_height + font:GetSpacing()
	local line_idx = math.floor(ry / vertical_step) + 1
	local wrapped_lines = text:split("\n", true)

	if line_idx < 1 then
		line_idx = 1
		rx = -1e9 -- Force to start of first line
	end

	if line_idx > #wrapped_lines then
		line_idx = #wrapped_lines
		rx = 1e9 -- Force to end of last line
	end

	local line_text = wrapped_lines[line_idx] or ""
	local char_idx_in_line = 1
	local chars = utf8.to_list(line_text)
	local cumulative_w = 0

	for i, char in ipairs(chars) do
		local cw = font:GetTextSize(char)

		if rx < cumulative_w + cw / 2 then
			char_idx_in_line = i

			goto found
		end

		cumulative_w = cumulative_w + cw
		char_idx_in_line = i + 1
	end

	::found::

	local raw_text = self:GetText()
	local text_list = utf8.to_list(raw_text)
	local wrapped_list = utf8.to_list(text)
	local t_idx, w_idx = 1, 1
	local cur_line, cur_col = 1, 1

	while t_idx <= #text_list + 1 and w_idx <= #wrapped_list + 1 do
		if cur_line == line_idx and cur_col == char_idx_in_line then return t_idx end

		local tc = text_list[t_idx]
		local wc = wrapped_list[w_idx]

		if tc == wc then
			if tc == "\n" then
				cur_line = cur_line + 1
				cur_col = 1
			else
				cur_col = cur_col + 1
			end

			t_idx = t_idx + 1
			w_idx = w_idx + 1
		elseif wc == "\n" then
			cur_line = cur_line + 1
			cur_col = 1
			w_idx = w_idx + 1

			if tc == " " then t_idx = t_idx + 1 end
		else
			t_idx = t_idx + 1
			w_idx = w_idx + 1
		end
	end

	return #text_list + 1
end

function META:GetLineColFromIndex(cursor)
	if self:GetWrap() and self.wrap_layout_info then
		local ranges = self.wrap_layout_info.ranges

		for i, range in ipairs(ranges) do
			if cursor < range.start then return i, 1 end

			local is_last = i == #ranges
			local visible_len = utf8.length(range.text)

			if
				(
					cursor >= range.start and
					cursor < range.stop
				)
				or
				(
					is_last and
					cursor <= range.stop
				)
			then
				return i, math.min(math.max(cursor - range.start + 1, 1), visible_len + 1)
			end
		end

		local last = ranges[#ranges]
		return #ranges, utf8.length(last.text) + 1
	end

	local text = self.wrapped_text or self:GetText()
	local raw_text = self:GetText()
	local text_idx = 1
	local wrapped_idx = 1
	local line, col = 1, 1
	local text_list = utf8.to_list(raw_text)
	local wrapped_list = utf8.to_list(text)

	while text_idx <= #text_list + 1 and wrapped_idx <= #wrapped_list + 1 do
		if text_idx == cursor then return line, col end

		local tc = text_list[text_idx]
		local wc = wrapped_list[wrapped_idx]

		if tc == wc then
			if tc == "\n" then
				line = line + 1
				col = 1
			else
				col = col + 1
			end

			text_idx = text_idx + 1
			wrapped_idx = wrapped_idx + 1
		elseif wc == "\n" then
			line = line + 1
			col = 1
			wrapped_idx = wrapped_idx + 1

			if tc == " " then text_idx = text_idx + 1 end
		else
			text_idx = text_idx + 1
			wrapped_idx = wrapped_idx + 1
		end
	end

	return line, col
end

function META:OnMouseInput(button, press, local_pos)
	if self:GetEditable() and button == "button_1" then
		if press then
			if self.editor then
				self.preferred_caret_x = nil
				local now = system.GetElapsedTime()
				local index = self:GetIndexAtPosition(local_pos.x, local_pos.y)

				if
					self.last_click_time and
					now - self.last_click_time < 0.4 and
					self.last_click_index == index
				then
					self.click_count = (self.click_count or 1) + 1
				else
					self.click_count = 1
				end

				self.last_click_time = now
				self.last_click_index = index

				if self.click_count == 2 then
					-- Double click: select word
					local buffer = self.editor.Buffer
					local text_len = buffer:GetLength()
					local char = buffer:Sub(index, index)

					local function get_char_class(c)
						if not c or c == "" then return "none" end

						if c:match("[%w_]") then return "word" end

						if c:match("%s") then return "space" end

						return "other"
					end

					local class = get_char_class(char)
					local start_idx = index

					while
						start_idx > 1 and
						get_char_class(buffer:Sub(start_idx - 1, start_idx - 1)) == class
					do
						start_idx = start_idx - 1
					end

					local stop_idx = index

					while
						stop_idx <= text_len and
						get_char_class(buffer:Sub(stop_idx, stop_idx)) == class
					do
						stop_idx = stop_idx + 1
					end

					self.editor:SetSelectionStart(start_idx)
					self.editor:SetCursor(stop_idx)
					self.dragging = false
					self:ResetCaretBlink()
				elseif self.click_count >= 3 then
					-- Triple click: select line
					local buffer = self.editor.Buffer
					local text_len = buffer:GetLength()
					local start_idx = index

					while start_idx > 1 and buffer:Sub(start_idx - 1, start_idx - 1) ~= "\n" do
						start_idx = start_idx - 1
					end

					local stop_idx = index

					while stop_idx <= text_len and buffer:Sub(stop_idx, stop_idx) ~= "\n" do
						stop_idx = stop_idx + 1
					end

					self.editor:SetSelectionStart(start_idx)
					self.editor:SetCursor(stop_idx)
					self.dragging = false
					self:ResetCaretBlink()
				else
					self.editor:SetSelectionStart(index)
					self.editor:SetCursor(index)
					self.dragging = true
					self:ResetCaretBlink()
				end

				return true
			end
		end
	end
end

return META:Register()
