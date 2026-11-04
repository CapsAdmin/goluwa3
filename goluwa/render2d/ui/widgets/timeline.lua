local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local input = import("goluwa/input.lua")
local META = Panel:CreateTemplate("timeline")
META.CMP.transform = {}
META.CMP.layout = {GrowWidth = 1, GrowHeight = 1}
META.CMP.visual = {}
META.CMP.mouse_input = {Cursor = "arrow"}
META:StartStorable()
META:GetSet("Rows", nil)
META:GetSet("Length", 1)
META:GetSet("Time", 0)
META:GetSet("Selection", nil)
META:GetSet("Snap", 0.005)
META:GetSet("LabelWidth", 96)
META:GetSet("AxisPadding", 14)
META:GetSet("RowHeight", 22)
META:GetSet("RulerHeight", 22)
META:EndStorable()
local KEY_RADIUS = 5
local PICK_RADIUS = 7
local MIN_SPAN = 0.02
local ZOOM_STEP = 1.2
local DOUBLE_CLICK = 0.3
local MARQUEE_DISTANCE = 3
local EDGE_RADIUS = 5
local MIN_SCALE = 0.05
local BAND_HEIGHT = 8
local PLAYHEAD_HEIGHT = 7

function META.OnScrub(time, timeline) end

function META.OnSelect(row, index, timeline) end

function META.OnKeyMove(row, index, time, timeline) end

function META.OnKeyDrop(row, index, timeline) end

function META.OnKeyAdd(row, time, timeline) end

function META.OnSelectKeys(selection, timeline) end

function META.OnKeysTransform(anchor, scale, offset, first, timeline) end

function META.OnKeysDrop(timeline) end

function META.OnKeyMenu(row, index, timeline) end

function META.OnRowAction(row, timeline) end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	self._from = 0
	self._to = self.Length
	self._drag = nil
	self._last_press = 0
end

function META:SetLength(length)
	self.Length = length
	self._from = math.clamp(self._from or 0, 0, length)
	self._to = math.clamp(self._to or length, self._from + MIN_SPAN, length)
end

function META:ResetView()
	self._from, self._to = 0, self.Length
end

function META:GetViewRange()
	return self._from, self._to
end

function META:get_axis_width()
	return self.transform:GetWidth() - self.LabelWidth - self.AxisPadding * 2
end

function META:time_to_x(time)
	local width = self:get_axis_width()
	return self.LabelWidth + self.AxisPadding + (
			time - self._from
		) / (
			self._to - self._from
		) * width
end

function META:key_x(key)
	return math.floor(self:time_to_x(key.Time)) + 0.5
end

function META:x_to_time(x)
	local width = self:get_axis_width()
	return self._from + (
			x - self.LabelWidth - self.AxisPadding
		) / width * (
			self._to - self._from
		)
end

function META:snap(time)
	local snap = self.Snap

	if snap > 0 then time = math.floor(time / snap + 0.5) * snap end

	return math.clamp(time, 0, self.Length)
end

function META:row_at(y)
	local index = math.floor((y - self.RulerHeight) / self.RowHeight) + 1
	local rows = self.Rows

	if rows and index >= 1 and index <= #rows then return index end
end

function META:key_at(local_pos)
	local row = self:row_at(local_pos.y)

	if not row or local_pos.x < self.LabelWidth then return end

	local best, best_distance

	for index, key in ipairs(self.Rows[row].Keys) do
		local distance = math.abs(self:time_to_x(key.Time) - local_pos.x)

		if distance <= PICK_RADIUS and (not best_distance or distance <= best_distance) then
			best, best_distance = index, distance
		end
	end

	return row, best
end

function META:scrub_to(local_pos)
	self.OnScrub(self:snap(self:x_to_time(local_pos.x)), self)
end

function META:is_selected(row, index)
	for _, item in ipairs(self.Selection or {}) do
		if item[1] == row and item[2] == index then return true end
	end

	return false
end

function META:get_selection_bounds()
	local selection = self.Selection

	if not selection or #selection < 2 then return end

	local first, last = math.huge, -math.huge

	for _, item in ipairs(selection) do
		local time = self.Rows[item[1]].Keys[item[2]].Time
		first, last = math.min(first, time), math.max(last, time)
	end

	return first, last
end

function META:band_at(local_pos)
	local first, last = self:get_selection_bounds()

	if
		not first or
		local_pos.y >= self.RulerHeight or
		local_pos.y < self.RulerHeight - BAND_HEIGHT - 2
	then
		return
	end

	local x1, x2 = self:time_to_x(first), self:time_to_x(last)

	if local_pos.x < x1 - EDGE_RADIUS or local_pos.x > x2 + EDGE_RADIUS then
		return
	end

	local near_left, near_right = math.abs(local_pos.x - x1), math.abs(local_pos.x - x2)

	if last > first and math.min(near_left, near_right) <= EDGE_RADIUS then
		return near_left <= near_right and "left" or "right", first, last
	end

	return "move", first, last
end

function META:begin_keys_drag(local_pos, kind, first, last)
	self._drag = {
		kind = kind,
		first = first,
		last = last,
		grab = self:x_to_time(local_pos.x),
		moved = false,
	}
end

function META:OnMouseMove(local_pos)
	local drag = self._drag
	local band = drag and drag.kind or self:band_at(local_pos)
	self.mouse_input:SetCursor((band == "left" or band == "right") and "horizontal_resize" or "arrow")
end

function META:OnMouseInput(button, press, local_pos)
	if button == "mwheel_up" or button == "mwheel_down" then
		if not press then return true end

		local anchor = math.clamp(self:x_to_time(local_pos.x), self._from, self._to)
		local factor = button == "mwheel_up" and 1 / ZOOM_STEP or ZOOM_STEP
		local span = math.clamp((self._to - self._from) * factor, MIN_SPAN, self.Length)
		local ratio = (anchor - self._from) / (self._to - self._from)
		local from = math.clamp(anchor - span * ratio, 0, self.Length - span)
		self._from, self._to = from, from + span
		return true
	end

	if button == "button_3" then
		self._drag = press and
			{kind = "pan", x = local_pos.x, from = self._from, to = self._to} or
			nil
		return true
	end

	if button == "button_2" then
		if not press then return true end

		local row, index = self:key_at(local_pos)

		if index then
			if not self:is_selected(row, index) then self.OnSelect(row, index, self) end

			self.OnKeyMenu(row, index, self)
		end

		return true
	end

	if button ~= "button_1" then return end

	if not press then
		self:end_drag()
		return true
	end

	local now = os.clock()
	local double = now - self._last_press < DOUBLE_CLICK
	self._last_press = now
	local band, first, last = self:band_at(local_pos)

	if band then
		self:begin_keys_drag(local_pos, band, first, last)
		return true
	end

	if local_pos.y < self.RulerHeight then
		if local_pos.x >= self.LabelWidth then
			self._drag = {kind = "scrub"}
			self:scrub_to(local_pos)
		end

		return true
	end

	local row, index = self:key_at(local_pos)
	local button_row = self:row_at(local_pos.y)

	if button_row and self.Rows[button_row].Button then
		self.OnRowAction(button_row, self)
		return true
	end

	if index and input.IsShiftDown() then
		local selection = {}
		local found

		for _, item in ipairs(self.Selection or {}) do
			if item[1] == row and item[2] == index then
				found = true
			else
				selection[#selection + 1] = item
			end
		end

		if not found then selection[#selection + 1] = {row, index} end

		self.OnSelectKeys(selection, self)
	elseif index and self:is_selected(row, index) and #self.Selection > 1 then
		local first, last = self:get_selection_bounds()
		self:begin_keys_drag(local_pos, "move", first, last)
		self._drag.narrow = {row, index}
	elseif index then
		self.OnSelect(row, index, self)
		self._drag = {
			kind = "key",
			row = row,
			index = index,
			grab = self.Rows[row].Keys[index].Time - self:x_to_time(local_pos.x),
			moved = false,
		}
	elseif row and double and local_pos.x >= self.LabelWidth then
		self.OnKeyAdd(row, self:snap(self:x_to_time(local_pos.x)), self)
	else
		self._drag = {
			kind = "marquee",
			x = local_pos.x,
			y = local_pos.y,
			x2 = local_pos.x,
			y2 = local_pos.y,
			base = input.IsShiftDown() and self.Selection or {},
			moved = false,
		}
	end

	return true
end

function META:end_drag(local_pos)
	local drag = self._drag
	self._drag = nil

	if not drag then return end

	if drag.kind == "key" and drag.moved then
		self.OnKeyDrop(drag.row, drag.index, self)
	elseif drag.kind == "marquee" then
		if not drag.moved then
			if not input.IsShiftDown() then self.OnSelect(nil, nil, self) end

			if drag.x >= self.LabelWidth then
				self.OnScrub(self:snap(self:x_to_time(drag.x)), self)
			end
		end
	elseif drag.moved then
		self.OnKeysDrop(self)
	elseif drag.narrow then
		self.OnSelect(drag.narrow[1], drag.narrow[2], self)
	end
end

function META:OnGlobalMouseInput(button, press)
	if self._drag and not press and (button == "button_1" or button == "button_3") then
		self:end_drag()
	end
end

function META:OnGlobalMouseMove(pos)
	local drag = self._drag

	if not drag then return end

	local local_pos = self.transform:GlobalToLocal(pos)

	if drag.kind == "marquee" then
		drag.x2, drag.y2 = local_pos.x, local_pos.y

		if
			not drag.moved and
			math.abs(drag.x2 - drag.x) < MARQUEE_DISTANCE and
			math.abs(drag.y2 - drag.y) < MARQUEE_DISTANCE
		then
			return true
		end

		drag.moved = true
		local selection = {}

		for _, item in ipairs(drag.base) do
			selection[#selection + 1] = item
		end

		local x1, x2 = math.min(drag.x, drag.x2), math.max(drag.x, drag.x2)
		local y1, y2 = math.min(drag.y, drag.y2), math.max(drag.y, drag.y2)

		for i, row in ipairs(self.Rows) do
			local top = self.RulerHeight + (i - 1) * self.RowHeight

			if top + self.RowHeight >= y1 and top <= y2 then
				for j, key in ipairs(row.Keys) do
					local x = self:time_to_x(key.Time)

					if x >= x1 and x <= x2 and x >= self.LabelWidth then
						local present

						for _, item in ipairs(selection) do
							if item[1] == i and item[2] == j then present = true end
						end

						if not present then selection[#selection + 1] = {i, j} end
					end
				end
			end
		end

		self.OnSelectKeys(selection, self)
	elseif drag.kind == "move" or drag.kind == "left" or drag.kind == "right" then
		local anchor, scale, offset = 0, 1, 0
		local time = self:x_to_time(local_pos.x)

		if drag.kind == "move" then
			offset = math.clamp(time - drag.grab, -drag.first, self.Length - drag.last)
			offset = self.Snap > 0 and math.floor(offset / self.Snap + 0.5) * self.Snap or offset
		else
			local width = drag.last - drag.first
			local edge = self:snap(time)

			if drag.kind == "left" then
				anchor = drag.last
				scale = math.clamp((drag.last - edge) / width, MIN_SCALE, drag.last / width)
			else
				anchor = drag.first
				scale = math.clamp((edge - drag.first) / width, MIN_SCALE, (self.Length - drag.first) / width)
			end
		end

		if scale ~= 1 or offset ~= 0 or drag.moved then
			self.OnKeysTransform(anchor, scale, offset, not drag.moved, self)
			drag.moved = true
		end
	elseif drag.kind == "scrub" then
		self:scrub_to(local_pos)
	elseif drag.kind == "pan" then
		local width = self:get_axis_width()
		local span = drag.to - drag.from
		local from = math.clamp(drag.from - (local_pos.x - drag.x) / width * span, 0, self.Length - span)
		self._from, self._to = from, from + span
	else
		local keys = self.Rows[drag.row].Keys
		local time = self:snap(self:x_to_time(local_pos.x) + drag.grab)
		local previous, following = keys[drag.index - 1], keys[drag.index + 1]
		time = math.clamp(
			time,
			previous and previous.Time + self.Snap or 0,
			following and following.Time - self.Snap or self.Length
		)

		if time ~= keys[drag.index].Time then
			drag.moved = true
			self.OnKeyMove(drag.row, drag.index, time, self)
		end
	end

	return true
end

do
	local function draw_key(x, y, radius, round)
		if round then
			render2d.PushBorderRadius(radius)
			render2d.DrawRectf(x - radius, y - radius, radius * 2, radius * 2)
			render2d.PopBorderRadius()
		else
			render2d.DrawRectf(x, y, radius * 1.45, radius * 1.45, math.rad(45), radius * 0.725, radius * 0.725)
		end
	end

	local function get_ruler_step(span, width)
		local target = span / math.max(width / 80, 1)
		local magnitude = 10 ^ math.floor(math.log10(target))

		for _, factor in ipairs{1, 2, 5, 10} do
			if magnitude * factor >= target then return magnitude * factor end
		end

		return magnitude * 10
	end

	function META:OnDraw()
		local active = theme.active
		local size = self.transform:GetSize()
		local font = active:GetFont("body", "XS")
		local label_width, row_height, ruler = self.LabelWidth, self.RowHeight, self.RulerHeight
		local surface, alt = active:GetColor("surface"), active:GetColor("surface_alt")
		local border, text = active:GetColor("border"), active:GetColor("text")
		local disabled, primary = active:GetColor("text_disabled"), active:GetColor("primary")
		render2d.SetTexture(nil)
		render2d.SetColor(surface.r, surface.g, surface.b, 1)
		render2d.DrawRect(0, 0, size.x, size.y)
		local rows = self.Rows or {}
		render2d.PushClipRect(label_width, 0, size.x - label_width, size.y)
		local step = get_ruler_step(self._to - self._from, size.x - label_width)
		local tick = math.ceil(self._from / step) * step

		while tick <= self._to + 1e-9 do
			local x = math.floor(self:time_to_x(tick))
			render2d.SetColor(border.r, border.g, border.b, 0.6)
			render2d.DrawRect(x, ruler - 5, 1, size.y)
			render2d.SetColor(disabled.r, disabled.g, disabled.b, 1)
			local label = string.format("%g", math.floor(tick * 1e4 + 0.5) / 1e4)
			local text_width, text_height = font:GetTextSize(label)
			font:DrawText(label, x - text_width / 2, ruler - 6 - text_height)
			tick = tick + step
		end

		for i, row in ipairs(rows) do
			local y = ruler + (i - 1) * row_height

			if row.Button then
				render2d.SetColor(primary.r, primary.g, primary.b, 0.12)
				render2d.DrawRect(label_width, y, size.x - label_width, row_height)
			elseif i % 2 == 0 then
				render2d.SetColor(alt.r, alt.g, alt.b, 0.5)
				render2d.DrawRect(label_width, y, size.x - label_width, row_height)
			end

			local color = row.Color and active:GetColor(row.Color) or primary

			for _, key in ipairs(row.Keys) do
				if key.Until and key.Until > key.Time then
					local x = self:key_x(key)
					render2d.SetColor(color.r, color.g, color.b, 0.35)
					render2d.DrawRect(x, y + row_height / 2 - 2, self:time_to_x(key.Until) - x, 4)
				end
			end
		end

		local linked_row, linked_y = {}, {}

		for i, row in ipairs(rows) do
			local cy = ruler + (i - 1) * row_height + row_height / 2

			for _, key in ipairs(row.Keys) do
				local link = key.Link

				if link then
					local above_y = linked_y[link]

					if above_y and linked_row[link] ~= i then
						render2d.SetColor(text.r, text.g, text.b, 0.45)
						render2d.DrawRect(math.floor(self:key_x(key)), above_y, 1, cy - above_y)
					end

					linked_row[link] = i
					linked_y[link] = cy
				end
			end
		end

		local selected_links = self._selected_links or {}
		self._selected_links = selected_links
		table.clear(selected_links)

		for _, item in ipairs(self.Selection or {}) do
			local link = rows[item[1]].Keys[item[2]].Link

			if link then selected_links[link] = true end
		end

		for i, row in ipairs(rows) do
			local y = ruler + (i - 1) * row_height
			local cy = y + row_height / 2
			local color = row.Color and active:GetColor(row.Color) or primary

			for j, key in ipairs(row.Keys) do
				local x = self:key_x(key)

				if self:is_selected(i, j) then
					render2d.SetColor(text.r, text.g, text.b, 1)
					draw_key(x, cy, KEY_RADIUS + 2, row.Round)
				elseif key.Link and selected_links[key.Link] then
					render2d.SetColor(text.r, text.g, text.b, 0.4)
					draw_key(x, cy, KEY_RADIUS + 2, row.Round)
				end

				render2d.SetColor(color.r, color.g, color.b, 1)
				draw_key(x, cy, KEY_RADIUS, row.Round)

				if key.Label and self._to - self._from < self.Length * 0.6 then
					render2d.SetColor(text.r, text.g, text.b, 0.8)
					font:DrawText(key.Label, x + KEY_RADIUS + 3, y + 4)
				end
			end
		end

		local first, last = self:get_selection_bounds()

		if first then
			local x1, x2 = self:time_to_x(first), self:time_to_x(last)
			render2d.SetColor(primary.r, primary.g, primary.b, 0.1)
			render2d.DrawRect(x1, ruler, x2 - x1, size.y - ruler)
			render2d.SetColor(primary.r, primary.g, primary.b, 0.9)
			render2d.DrawRect(x1, ruler - BAND_HEIGHT - 1, x2 - x1, BAND_HEIGHT)
			render2d.SetColor(text.r, text.g, text.b, 1)
			render2d.DrawRect(x1 - 1, ruler - BAND_HEIGHT - 1, 3, BAND_HEIGHT)
			render2d.DrawRect(x2 - 2, ruler - BAND_HEIGHT - 1, 3, BAND_HEIGHT)
		end

		local drag = self._drag

		if drag and drag.kind == "marquee" and drag.moved then
			local x, y = math.min(drag.x, drag.x2), math.min(drag.y, drag.y2)
			local w, h = math.abs(drag.x2 - drag.x), math.abs(drag.y2 - drag.y)
			render2d.SetColor(primary.r, primary.g, primary.b, 0.15)
			render2d.DrawRect(x, y, w, h)
			render2d.SetColor(primary.r, primary.g, primary.b, 0.8)
			render2d.DrawRect(x, y, w, 1)
			render2d.DrawRect(x, y + h - 1, w, 1)
			render2d.DrawRect(x, y, 1, h)
			render2d.DrawRect(x + w - 1, y, 1, h)
		end

		local playhead = math.floor(self:time_to_x(self.Time))
		render2d.SetColor(primary.r, primary.g, primary.b, 1)
		render2d.DrawRect(playhead, 0, 1, size.y)
		render2d.SetColor(primary.r, primary.g, primary.b, 0.5)
		render2d.DrawRect(playhead - 1, PLAYHEAD_HEIGHT, 1, size.y - PLAYHEAD_HEIGHT)
		render2d.DrawRect(playhead + 1, PLAYHEAD_HEIGHT, 1, size.y - PLAYHEAD_HEIGHT)
		render2d.SetColor(primary.r, primary.g, primary.b, 1)

		for row = 0, PLAYHEAD_HEIGHT - 1 do
			local half = PLAYHEAD_HEIGHT - 1 - row
			render2d.DrawRect(playhead - half, row, half * 2 + 1, 1)
		end

		render2d.PopClip()
		render2d.SetColor(surface.r, surface.g, surface.b, 1)
		render2d.DrawRect(0, 0, label_width, size.y)
		render2d.SetColor(border.r, border.g, border.b, 1)
		render2d.DrawRect(label_width - 1, 0, 1, size.y)
		render2d.DrawRect(0, ruler - 1, size.x, 1)

		for i, row in ipairs(rows) do
			local c = row.Button and primary or text
			render2d.SetColor(c.r, c.g, c.b, 1)
			font:DrawText(row.Name, 6, ruler + (i - 1) * row_height + 4)
		end
	end
end

return META:Register()
