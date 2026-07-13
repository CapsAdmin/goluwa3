hook.Remove("HUDPaint", "GoluwaSurfaceTextProbe")

local function fill_rect(x, y, w, h, color)
	surface.SetDrawColor(color.r, color.g, color.b, color.a or 255)
	surface.DrawRect(x, y, w, h)
end

local function outline_rect(x, y, w, h, color)
	surface.SetDrawColor(color.r, color.g, color.b, color.a or 255)
	surface.DrawOutlinedRect(math.floor(x), math.floor(y), math.max(math.floor(w), 0), math.max(math.floor(h), 0))
end

local function draw_label(text, x, y, color, font)
	surface.SetFont(font or "DermaDefault")
	surface.SetTextColor(color.r, color.g, color.b, color.a or 255)
	surface.SetTextPos(x, y)
	surface.DrawText(text)
end

local function split_lines(text)
	local out = {}

	for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
		out[#out + 1] = line
	end

	if #out == 0 then out[1] = "" end

	return out
end

local function measure_layout(text, font)
	surface.SetFont(font)
	local lines = split_lines(text)
	local max_w = 0
	local _, line_h = surface.GetTextSize("|")

	for _, line in ipairs(lines) do
		local line_w = select(1, surface.GetTextSize(line))
		max_w = math.max(max_w, line_w)
	end

	return max_w, line_h * #lines, line_h, lines
end

local function draw_text_block(x, y, title, font, text)
	local measured_w, measured_h, line_h, lines = measure_layout(text, font)
	surface.SetFont(font)
	outline_rect(x, y, measured_w, measured_h, Color(255, 120, 120))
	surface.SetDrawColor(255, 120, 120, 255)
	surface.DrawLine(math.floor(x), y - 8, math.floor(x), y + measured_h + 8)
	surface.DrawLine(x - 8, math.floor(y), x + measured_w + 8, math.floor(y))

	for index = 1, #lines - 1 do
		local line_y = y + index * line_h
		surface.SetDrawColor(90, 120, 150, 180)
		surface.DrawLine(x, line_y, x + measured_w, line_y)
	end

	for index, line in ipairs(lines) do
		local line_y = y + (index - 1) * line_h
		local line_w = select(1, surface.GetTextSize(line))
		outline_rect(x, line_y, line_w, line_h, Color(120, 255, 160))
		surface.SetFont(font)
		surface.SetTextColor(220, 230, 245, 255)
		surface.SetTextPos(x, line_y)
		surface.DrawText(line)
	end

	draw_label(title, x, y - 18, Color(255, 255, 255), "DermaDefaultBold")
	draw_label(
		string.format(
			"measure=(%d,%d) lines=%d line_h=%d first_line=(%d,%d)",
			math.floor(measured_w),
			math.floor(measured_h),
			#lines,
			math.floor(line_h),
			math.floor(select(1, surface.GetTextSize(lines[1] or ""))),
			math.floor(select(2, surface.GetTextSize(lines[1] or "")))
		),
		x,
		y + measured_h + 8,
		Color(235, 235, 210),
		"DermaDefault"
	)
	return measured_h + 34
end

hook.Add("HUDPaint", "GoluwaSurfaceTextProbe", function()
	local sw, sh = ScrW(), ScrH()
	local left = 24
	local top = 40
	local width = math.min(sw - 48, 920)
	local height = math.min(sh - 80, 760)
	fill_rect(left, top, width, height, Color(28, 31, 37, 245))
	outline_rect(left, top, width, height, Color(90, 96, 110))
	fill_rect(left + 12, top + 12, width - 24, 50, Color(36, 40, 48, 255))
	outline_rect(left + 12, top + 12, width - 24, 50, Color(82, 90, 106))
	draw_label(
		"Pure surface.DrawText probe: red = measured multiline block, green = per-line boxes from public surface.GetTextSize.",
		left + 20,
		top + 22,
		Color(255, 255, 255),
		"DermaDefaultBold"
	)
	draw_label(
		"This bypasses VGUI entirely and uses only public surface APIs, so it does not rely on internal glyph-bounds helpers.",
		left + 20,
		top + 42,
		Color(210, 214, 222),
		"DermaDefault"
	)
	local cursor_y = top + 92
	local column_x = left + 22
	local right_x = left + math.floor(width / 2) + 8
	cursor_y = cursor_y + draw_text_block(column_x, cursor_y, "Single line descenders", "DermaDefault", "AgjpQy 0123") + 26
	cursor_y = cursor_y + draw_text_block(column_x, cursor_y, "Leading spaces", "DermaDefault", "   padded text") + 26
	cursor_y = cursor_y + draw_text_block(column_x, cursor_y, "Tabs and spacing", "DermaDefault", "col1\tcol2\tcol3") + 26
	local right_y = top + 92
	right_y = right_y + draw_text_block(right_x, right_y, "Two lines", "DermaDefault", "first line\nsecond line") + 26
	right_y = right_y + draw_text_block(right_x, right_y, "Mixed heights", "DermaLarge", "AgjpQy\n0123") + 26
	right_y = right_y + draw_text_block(right_x, right_y, "Empty middle line", "DermaDefault", "top\n\nbottom") + 26
	draw_label("Legend", left + 22, top + height - 74, Color(255, 255, 255), "DermaDefaultBold")
	draw_label(
		"Red box/lines: logical measured block anchored at requested text position.",
		left + 22,
		top + height - 54,
		Color(255, 190, 190),
		"DermaDefault"
	)
	draw_label(
		"Green boxes: per-line width/height from public surface.GetTextSize for each drawn line.",
		left + 22,
		top + height - 36,
		Color(190, 255, 210),
		"DermaDefault"
	)
	draw_label(
		"Blue separators inside multiline blocks mark line-height stepping.",
		left + 22,
		top + height - 18,
		Color(180, 210, 255),
		"DermaDefault"
	)
end)
