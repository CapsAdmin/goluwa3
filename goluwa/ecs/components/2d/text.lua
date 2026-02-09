local prototype = require("prototype")
local fonts = require("render2d.fonts")
local render2d = require("render2d.render2d")
local Color = require("structs.color")
local Vec2 = require("structs.vec2")
local system = require("system")
local sequence_editor = require("sequence_editor")
local utf8 = require("utf8")
local META = prototype.CreateTemplate("text")
META:StartStorable()
META:GetSet(
	"Font",
	fonts.LoadFont(fonts.GetSystemDefaultFont(), 14),
	{callback = "OnTextChanged"}
)
META:GetSet("Text", "", {callback = "OnTextChanged"})
META:GetSet("Wrap", false, {callback = "OnTextChanged"})
META:GetSet("WrapToParent", false, {callback = "OnTextChanged"})
META:GetSet("AlignX", "left", {callback = "OnTextChanged"})
META:GetSet("AlignY", "top", {callback = "OnTextChanged"})
META:GetSet("Color", Color(1, 1, 1, 1))
META:GetSet("Editable", false, {callback = "OnEditableChanged"})
META:EndStorable()

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
		end
	end
end

function META:Initialize()
	self:OnEditableChanged()
	self:OnTextChanged()

	self.Owner:AddLocalListener("OnDraw", function()
		self:OnDraw()
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

				if press then self.editor:OnKeyInput(key) end
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
				self.editor:OnCharInput(char)
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
				self.editor:SetCursor(index)
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
			local width = self.Owner.transform.Size.x

			if
				self:GetWrapToParent() and
				self.Owner:GetParent() and
				self.Owner:GetParent().transform
			then
				width = self.Owner:GetParent().transform.Size.x
			end

			if self.last_wrap_width ~= width then
				self.last_wrap_width = width
				self:OnTextChanged()
			end
		end
	end)
end

function META:GetTextSize()
	local font = self:GetFont() or fonts.GetDefaultFont()
	return font:GetTextSize(self.wrapped_text or self:GetText())
end

function META:Measure(available_width, available_height)
	local font = self:GetFont() or fonts.GetDefaultFont()
	local text = self:GetText()

	if self:GetWrap() then
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

		local wrapped = font:WrapString(text, width)
		local w, h = font:GetTextSize(wrapped)

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
	local font = self:GetFont() or fonts.GetDefaultFont()
	local text = self:GetText()

	if self.editor and not self._is_updating_from_editor then
		if self.editor:GetText() ~= text then self.editor:SetText(text) end
	end

	if self:GetWrap() then
		local width = self.Owner.transform.Size.x

		if
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

		self.wrapped_text = font:WrapString(text, width)
	else
		self.wrapped_text = text
	end

	local w, h = self:GetTextSize()

	if not self:GetWrap() then
		self.Owner.transform:SetSize(Vec2(w, h))
	else
		-- When wrapping, we update our height to match the text
		-- but we don't want to shrink our width to the tight bounding box
		-- as that causes feedback loops with layouts that FitWidth.
		self.Owner.transform:SetHeight(h)
	end

	if self.Owner.layout then self.Owner.layout:InvalidateLayout() end

	if self.Owner:HasParent() and self.Owner:GetParent().layout then
		self.Owner:GetParent().layout:InvalidateLayout()
	end
end

function META:GetWrappedSize(width)
	local font = self:GetFont() or fonts.GetDefaultFont()
	local text = self:GetText()

	if self:GetWrap() then
		local wrapped = font:WrapString(text, width or self.Owner.transform.Size.x)
		local w, h = font:GetTextSize(wrapped)
		return Vec2(w, h)
	end

	local w, h = font:GetTextSize(text)
	return Vec2(w, h)
end

function META:OnDraw()
	local font = self:GetFont() or fonts.GetDefaultFont()
	local text = self.wrapped_text or self:GetText()
	local x, y = 0, 0
	local ax, ay = self:GetAlignX(), self:GetAlignY()
	local size = self.Owner.transform.Size

	if type(ax) == "number" then
		x = size.x * ax
	elseif ax == "center" then
		x = size.x / 2
	elseif ax == "right" then
		x = size.x
	end

	if type(ay) == "number" then
		y = size.y * ay
	elseif ay == "center" then
		y = size.y / 2
	elseif ay == "bottom" then
		y = size.y
	end

	local lx, ly = self:GetTextOffset()

	if self:GetEditable() and self.editor and prototype.GetFocusedObject() == self.Owner then
		local start, stop = self.editor:GetSelection()

		if start and start ~= stop then
			local line_height = font:GetLineHeight()
			local vertical_step = line_height + font:GetSpacing()
			local lines = text:split("\n", true)
			local line_start, col_start = self:GetLineColFromIndex(start)
			local line_stop, col_stop = self:GetLineColFromIndex(stop)
			render2d.SetColor(1, 1, 1, 0.3)
			render2d.SetTexture(nil)

			for i = line_start, line_stop do
				local line_text = lines[i] or ""
				local c_start = (i == line_start) and col_start or 1
				local c_stop = (i == line_stop) and col_stop or utf8.length(line_text) + 1
				local prefix = utf8.sub(line_text, 1, c_start - 1)
				local middle = utf8.sub(line_text, c_start, math.max(c_start, c_stop - 1))
				local x_offset = font:GetTextSize(prefix)
				local width = font:GetTextSize(middle)

				if i < line_stop then width = math.max(width, 5) end

				render2d.DrawRect(lx + x_offset, ly + (i - 1) * vertical_step, width, line_height)
			end
		end
	end

	render2d.SetColor(self:GetColor():Unpack())
	font:DrawText(text, x, y, 0, ax, ay)

	if
		self:GetEditable() and
		self.editor and
		prototype.GetFocusedObject() == self.Owner and
		(
			system.GetElapsedTime() * 2
		) % 2 < 1
	then
		local cursor = self.editor.Cursor
		local found_line, found_col = self:GetLineColFromIndex(cursor)
		local lines = text:split("\n", true)
		local line_text = lines[found_line] or ""
		local prefix = utf8.sub(line_text, 1, found_col - 1)
		local cw = font:GetTextSize(prefix)
		local line_height = font:GetLineHeight()
		local vertical_step = line_height + font:GetSpacing()
		render2d.SetColor(self:GetColor():Unpack())
		render2d.SetTexture(nil)
		render2d.DrawRect(lx + cw, ly + (found_line - 1) * vertical_step, 1, line_height)
	end
end

function META:GetTextOffset()
	local font = self:GetFont() or fonts.GetDefaultFont()
	local text = self.wrapped_text or self:GetText()
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
	end

	local tw, th = font:GetTextSize(text)
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
	end

	return lx, ly
end

function META:GetIndexAtPosition(mx, my)
	local font = self:GetFont() or fonts.GetDefaultFont()
	local text = self.wrapped_text or self:GetText()
	local lx, ly = self:GetTextOffset()
	local rx, ry = mx - lx, my - ly
	local line_height = font:GetLineHeight()
	local vertical_step = line_height + font:GetSpacing()
	local line_idx = math.floor(ry / vertical_step) + 1
	local wrapped_lines = text:split("\n", true)

	if line_idx < 1 then line_idx = 1 end

	if line_idx > #wrapped_lines then line_idx = #wrapped_lines end

	local line_text = wrapped_lines[line_idx] or ""
	local char_idx_in_line = 1
	local chars = utf8.to_list(line_text)
	local cumulative_w = 0

	for i, char in ipairs(chars) do
		local cw = font:GetTextSize(char)

		if rx < cumulative_w + cw / 2 then
			char_idx_in_line = i

			break
		end

		cumulative_w = cumulative_w + cw
		char_idx_in_line = i + 1
	end

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
				else
					self.editor:SetSelectionStart(index)
					self.editor:SetCursor(index)
					self.dragging = true
				end

				return true
			end
		end
	end
end

return META:Register()
