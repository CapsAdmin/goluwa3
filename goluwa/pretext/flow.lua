local line_break = import("goluwa/pretext/line_break.lua")
local flow = library()
local math_abs = math.abs
local math_ceil = math.ceil
local math_floor = math.floor
local math_huge = math.huge
local math_max = math.max
local math_min = math.min
local math_sqrt = math.sqrt

local function clone_cursor(cursor)
	return {
		segment_index = cursor.segment_index,
		grapheme_index = cursor.grapheme_index,
	}
end

local function cursor_equal(a, b)
	if not a or not b then return false end

	return a.segment_index == b.segment_index and a.grapheme_index == b.grapheme_index
end

local function clamp_interval(interval, left, right)
	local clamped_left = math_max(left, interval.left)
	local clamped_right = math_min(right, interval.right)

	if clamped_right <= clamped_left then return nil end

	return {
		left = clamped_left,
		right = clamped_right,
	}
end

local function normalize_rect(rect)
	return {
		x = rect.x or 0,
		y = rect.y or 0,
		width = rect.width or rect.w or 0,
		height = rect.height or rect.h or 0,
	}
end

local function get_polygon_xs_at_y(points, y)
	local xs = {}
	local prev = #points

	for index = 1, #points do
		local a = points[index]
		local b = points[prev]

		if (a.y > y) ~= (b.y > y) then
			local ratio = (y - a.y) / (b.y - a.y)
			xs[#xs + 1] = a.x + (b.x - a.x) * ratio
		end

		prev = index
	end

	table.sort(xs)
	return xs
end

function flow.get_rect_intervals_for_band(rects, band_top, band_bottom, horizontal_padding, vertical_padding)
	horizontal_padding = horizontal_padding or 0
	vertical_padding = vertical_padding or 0
	local intervals = {}

	for i = 1, #rects do
		local rect = normalize_rect(rects[i])

		if
			band_bottom > rect.y - vertical_padding and
			band_top < rect.y + rect.height + vertical_padding
		then
			intervals[#intervals + 1] = {
				left = rect.x - horizontal_padding,
				right = rect.x + rect.width + horizontal_padding,
			}
		end
	end

	return intervals
end

function flow.get_circle_interval_for_band(circle, band_top, band_bottom, horizontal_padding, vertical_padding)
	horizontal_padding = horizontal_padding or circle.horizontal_padding or circle.hPad or 0
	vertical_padding = vertical_padding or circle.vertical_padding or circle.vPad or 0
	local cx = circle.cx or circle.x or 0
	local cy = circle.cy or circle.y or 0
	local radius = circle.radius or circle.r or 0
	local sample_top = band_top - vertical_padding
	local sample_bottom = band_bottom + vertical_padding
	local dy = 0

	if cy < sample_top then
		dy = sample_top - cy
	elseif cy > sample_bottom then
		dy = cy - sample_bottom
	end

	if dy >= radius then return nil end

	local dx = math_sqrt(math_max(0, radius * radius - dy * dy))
	return {
		left = cx - dx - horizontal_padding,
		right = cx + dx + horizontal_padding,
	}
end

function flow.get_polygon_interval_for_band(points, band_top, band_bottom, horizontal_padding, vertical_padding)
	horizontal_padding = horizontal_padding or 0
	vertical_padding = vertical_padding or 0
	local sample_top = band_top - vertical_padding
	local sample_bottom = band_bottom + vertical_padding
	local start_y = math_floor(sample_top)
	local end_y = math_ceil(sample_bottom)
	local left = math_huge
	local right = -math_huge

	for y = start_y, end_y do
		local xs = get_polygon_xs_at_y(points, y + 0.5)

		for index = 1, #xs - 1, 2 do
			left = math_min(left, xs[index])
			right = math_max(right, xs[index + 1])
		end
	end

	if left == math_huge or right == -math_huge then return nil end

	return {
		left = left - horizontal_padding,
		right = right + horizontal_padding,
	}
end

function flow.get_obstacle_intervals(obstacles, band_top, band_bottom)
	local blocked = {}

	for i = 1, #obstacles do
		local obstacle = obstacles[i]
		local kind = obstacle.kind or "rect"

		if kind == "rect" then
			local intervals = flow.get_rect_intervals_for_band(
				{obstacle},
				band_top,
				band_bottom,
				obstacle.horizontal_padding or obstacle.hPad,
				obstacle.vertical_padding or obstacle.vPad
			)

			for j = 1, #intervals do
				blocked[#blocked + 1] = intervals[j]
			end
		elseif kind == "rects" then
			local intervals = flow.get_rect_intervals_for_band(
				obstacle.rects or {},
				band_top,
				band_bottom,
				obstacle.horizontal_padding or obstacle.hPad,
				obstacle.vertical_padding or obstacle.vPad
			)

			for j = 1, #intervals do
				blocked[#blocked + 1] = intervals[j]
			end
		elseif kind == "circle" then
			local interval = flow.get_circle_interval_for_band(
				obstacle,
				band_top,
				band_bottom,
				obstacle.horizontal_padding or obstacle.hPad,
				obstacle.vertical_padding or obstacle.vPad
			)

			if interval then blocked[#blocked + 1] = interval end
		elseif kind == "polygon" then
			local interval = flow.get_polygon_interval_for_band(
				obstacle.points or {},
				band_top,
				band_bottom,
				obstacle.horizontal_padding or obstacle.hPad,
				obstacle.vertical_padding or obstacle.vPad
			)

			if interval then blocked[#blocked + 1] = interval end
		end
	end

	return blocked
end

function flow.carve_text_line_slots(base, blocked, min_width)
	min_width = min_width or 0
	local slots = {
		{left = base.left, right = base.right},
	}

	for i = 1, #blocked do
		local interval = blocked[i]
		local next_slots = {}

		for j = 1, #slots do
			local slot = slots[j]

			if interval.right <= slot.left or interval.left >= slot.right then
				next_slots[#next_slots + 1] = slot
			else
				if interval.left > slot.left then
					next_slots[#next_slots + 1] = {left = slot.left, right = interval.left}
				end

				if interval.right < slot.right then
					next_slots[#next_slots + 1] = {left = interval.right, right = slot.right}
				end
			end
		end

		slots = next_slots
	end

	local result = {}

	for i = 1, #slots do
		local slot = slots[i]

		if slot.right - slot.left >= min_width then result[#result + 1] = slot end
	end

	table.sort(result, function(a, b)
		return a.left < b.left
	end)

	return result
end

function flow.layout(prepared, region, line_height, obstacles, options)
	options = options or {}
	obstacles = obstacles or {}
	region = normalize_rect(region)
	line_height = line_height or prepared.line_height or 0
	local min_slot_width = options.min_slot_width or 0
	local use_all_slots = options.use_all_slots ~= false
	local cursor = clone_cursor(options.start_cursor or {segment_index = 1, grapheme_index = 1})
	local y = region.y
	local lines = {}
	local band_index = 1

	while y + line_height <= region.y + region.height do
		local band_top = y
		local band_bottom = y + line_height
		local blocked = flow.get_obstacle_intervals(obstacles, band_top, band_bottom)

		for i = 1, #blocked do
			blocked[i] = clamp_interval(blocked[i], region.x, region.x + region.width)
		end

		local clamped_blocked = {}

		for i = 1, #blocked do
			if blocked[i] then clamped_blocked[#clamped_blocked + 1] = blocked[i] end
		end

		local slots = flow.carve_text_line_slots(
			{left = region.x, right = region.x + region.width},
			clamped_blocked,
			min_slot_width
		)

		if #slots > 0 then
			local selected_slots = slots

			if not use_all_slots then
				local best = slots[1]
				local best_width = best.right - best.left

				for i = 2, #slots do
					local candidate = slots[i]
					local candidate_width = candidate.right - candidate.left

					if candidate_width > best_width then
						best = candidate
						best_width = candidate_width
					end
				end

				selected_slots = {best}
			end

			for i = 1, #selected_slots do
				local slot = selected_slots[i]
				local before = clone_cursor(cursor)
				local line = line_break.layout_next_line(prepared, cursor, slot.right - slot.left)

				if not line then
					return {
						lines = lines,
						cursor = cursor,
						done = true,
						height = y - region.y,
						band_count = band_index - 1,
					}
				end

				lines[#lines + 1] = {
					text = line.text,
					x = slot.left,
					y = y,
					width = line.width,
					slot = slot,
					band_index = band_index,
					start = line.start,
					["end"] = line["end"],
				}
				cursor = clone_cursor(line["end"])

				if cursor_equal(before, cursor) then
					return {
						lines = lines,
						cursor = cursor,
						done = false,
						height = y - region.y + line_height,
						band_count = band_index,
					}
				end
			end
		end

		y = y + line_height
		band_index = band_index + 1
	end

	return {
		lines = lines,
		cursor = cursor,
		done = false,
		height = y - region.y,
		band_count = band_index - 1,
	}
end

return flow
