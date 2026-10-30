local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
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
META:GetSet("RowHeight", 22)
META:GetSet("RulerHeight", 22)
META:EndStorable()
local KEY_RADIUS = 5
local PICK_RADIUS = 7
local MIN_SPAN = 0.02
local ZOOM_STEP = 1.2
local DOUBLE_CLICK = 0.3

function META.OnScrub(time, timeline) end

function META.OnSelect(row, index, timeline) end

function META.OnKeyMove(row, index, time, timeline) end

function META.OnKeyDrop(row, index, timeline) end

function META.OnKeyAdd(row, time, timeline) end

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

function META:time_to_x(time)
	local width = self.transform:GetWidth() - self.LabelWidth
	return self.LabelWidth + (time - self._from) / (self._to - self._from) * width
end

function META:x_to_time(x)
	local width = self.transform:GetWidth() - self.LabelWidth
	return self._from + (x - self.LabelWidth) / width * (self._to - self._from)
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

	if button ~= "button_1" then return end

	if not press then
		self:end_drag()
		return true
	end

	local now = os.clock()
	local double = now - self._last_press < DOUBLE_CLICK
	self._last_press = now

	if local_pos.y < self.RulerHeight then
		if local_pos.x >= self.LabelWidth then
			self._drag = {kind = "scrub"}
			self:scrub_to(local_pos)
		end

		return true
	end

	local row, index = self:key_at(local_pos)

	if index then
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
		self.OnSelect(nil, nil, self)

		if local_pos.x >= self.LabelWidth then
			self._drag = {kind = "scrub"}
			self:scrub_to(local_pos)
		end
	end

	return true
end

function META:end_drag()
	local drag = self._drag
	self._drag = nil

	if drag and drag.kind == "key" and drag.moved then
		self.OnKeyDrop(drag.row, drag.index, self)
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

	if drag.kind == "scrub" then
		self:scrub_to(local_pos)
	elseif drag.kind == "pan" then
		local width = self.transform:GetWidth() - self.LabelWidth
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
			render2d.DrawFilledCircle(x, y, radius)
		else
			render2d.DrawRect(x, y, radius * 1.45, radius * 1.45, math.rad(45), radius * 0.725, radius * 0.725)
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
		local selection = self.Selection
		render2d.PushClipRect(label_width, 0, size.x - label_width, size.y)
		local step = get_ruler_step(self._to - self._from, size.x - label_width)
		local tick = math.ceil(self._from / step) * step

		while tick <= self._to + 1e-9 do
			local x = math.floor(self:time_to_x(tick))
			render2d.SetColor(border.r, border.g, border.b, 0.6)
			render2d.DrawRect(x, ruler - 5, 1, size.y)
			render2d.SetColor(disabled.r, disabled.g, disabled.b, 1)
			font:DrawText(string.format("%g", math.floor(tick * 1e4 + 0.5) / 1e4), x + 3, 2)
			tick = tick + step
		end

		for i, row in ipairs(rows) do
			local y = ruler + (i - 1) * row_height

			if i % 2 == 0 then
				render2d.SetColor(alt.r, alt.g, alt.b, 0.5)
				render2d.DrawRect(label_width, y, size.x - label_width, row_height)
			end

			local color = row.Color and active:GetColor(row.Color) or primary
			local keys = row.Keys

			for j, key in ipairs(keys) do
				local x = self:time_to_x(key.Time)

				if key.Until and key.Until > key.Time then
					render2d.SetColor(color.r, color.g, color.b, 0.35)
					render2d.DrawRect(x, y + row_height / 2 - 2, self:time_to_x(key.Until) - x, 4)
				end
			end

			for j, key in ipairs(keys) do
				local x = self:time_to_x(key.Time)
				local selected = selection and selection[1] == i and selection[2] == j
				local cy = y + row_height / 2

				if selected then
					render2d.SetColor(text.r, text.g, text.b, 1)
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

		local playhead = self:time_to_x(self.Time)
		render2d.SetColor(primary.r, primary.g, primary.b, 1)
		render2d.DrawRect(playhead - 0.5, 0, 2, size.y)
		render2d.DrawRect(playhead - 5, 0, 10, ruler - 8)
		render2d.PopClip()
		render2d.SetColor(surface.r, surface.g, surface.b, 1)
		render2d.DrawRect(0, 0, label_width, size.y)
		render2d.SetColor(border.r, border.g, border.b, 1)
		render2d.DrawRect(label_width - 1, 0, 1, size.y)
		render2d.DrawRect(0, ruler - 1, size.x, 1)

		for i, row in ipairs(rows) do
			render2d.SetColor(text.r, text.g, text.b, 1)
			font:DrawText(row.Name, 6, ruler + (i - 1) * row_height + 4)
		end
	end
end

return META:Register()
