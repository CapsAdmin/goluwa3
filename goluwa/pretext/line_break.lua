local utf8 = import("goluwa/utf8.lua")
local line_break = library()
local math_huge = math.huge

local function clone_cursor(cursor)
	return {
		segment_index = cursor.segment_index,
		grapheme_index = cursor.grapheme_index,
	}
end

local function after_segment(index)
	return {segment_index = index + 1, grapheme_index = 1}
end

local function cursor_less_than(a, b)
	return a.segment_index < b.segment_index or
		(
			a.segment_index == b.segment_index and
			a.grapheme_index < b.grapheme_index
		)
end

local function get_tab_width(prepared, current_width)
	local measurer = prepared.measurer

	if type(measurer.GetTabAdvance) == "function" then
		return measurer:GetTabAdvance(prepared.space_width, prepared.options.tab_size, current_width) or
			0
	end

	if type(measurer.GetTabWidth) == "function" then
		return measurer:GetTabWidth(prepared.space_width, prepared.options.tab_size, current_width) or
			0
	end

	return prepared.space_width * prepared.options.tab_size
end

local function measure_partial(segment, start_grapheme, end_grapheme)
	if
		segment.kind == "hard_break" or
		segment.kind == "zero_width_break" or
		segment.kind == "soft_hyphen"
	then
		return 0
	end

	if not segment.prefix_widths then return segment.width or 0 end

	local first = start_grapheme > 1 and segment.prefix_widths[start_grapheme - 1] or 0
	local last = segment.prefix_widths[end_grapheme - 1] or 0
	return last - first
end

local function can_break_between(previous_segment, next_segment)
	if not previous_segment or not next_segment then return true end

	if next_segment.forbid_line_start then return false end

	if previous_segment.forbid_line_end then return false end

	return true
end

local function normalize_line_start(prepared, cursor)
	local normalized = clone_cursor(cursor)
	local preserve_spaces = prepared.options.white_space == "pre-wrap"

	while true do
		local segment = prepared.segments[normalized.segment_index]

		if not segment then return normalized end

		if segment.kind == "hard_break" then return normalized end

		if preserve_spaces then return normalized end

		if
			segment.kind == "space" or
			segment.kind == "preserved_space" or
			segment.kind == "tab" or
			segment.kind == "zero_width_break" or
			segment.kind == "soft_hyphen"
		then
			normalized = after_segment(normalized.segment_index)
		else
			return normalized
		end
	end
end

local function build_line(start_cursor, end_cursor, width, soft_hyphen)
	return {
		start = start_cursor,
		["end"] = end_cursor,
		width = width,
		soft_hyphen = soft_hyphen or false,
	}
end

local function fit_segment_prefix(segment, available_width)
	if not segment.prefix_widths then return nil, nil end

	for i = 1, #segment.prefix_widths do
		if segment.prefix_widths[i] > available_width then
			if i == 1 then return 1, segment.prefix_widths[1] end

			return i - 1, segment.prefix_widths[i - 1]
		end
	end

	return #segment.prefix_widths, segment.prefix_widths[#segment.prefix_widths]
end

function line_break.layout_next_line_range(prepared, start_cursor, max_width)
	max_width = max_width or math_huge
	start_cursor = normalize_line_start(prepared, start_cursor or {segment_index = 1, grapheme_index = 1})

	while true do
		local segment = prepared.segments[start_cursor.segment_index]

		if not segment then return nil end

		if not segment.graphemes or #segment.graphemes == 0 then break end

		if start_cursor.grapheme_index <= #segment.graphemes then break end

		start_cursor = normalize_line_start(prepared, after_segment(start_cursor.segment_index))
	end

	local start_segment = prepared.segments[start_cursor.segment_index]

	if not start_segment then return nil end

	if start_segment.kind == "hard_break" then
		return build_line(clone_cursor(start_cursor), after_segment(start_cursor.segment_index), 0, false)
	end

	local current_width = 0
	local cursor = clone_cursor(start_cursor)
	local last_break = nil
	local has_content = false

	while true do
		local segment = prepared.segments[cursor.segment_index]

		if not segment then
			if not has_content then return nil end

			return build_line(clone_cursor(start_cursor), clone_cursor(cursor), current_width, false)
		end

		if
			segment.graphemes and
			#segment.graphemes > 0 and
			cursor.grapheme_index > #segment.graphemes
		then
			cursor = after_segment(cursor.segment_index)
		else
			if segment.kind == "hard_break" then
				return build_line(
					clone_cursor(start_cursor),
					after_segment(cursor.segment_index),
					current_width,
					false
				)
			end

			if segment.kind == "zero_width_break" then
				last_break = {
					cursor = after_segment(cursor.segment_index),
					width = current_width,
					soft_hyphen = false,
				}
				cursor = after_segment(cursor.segment_index)
			elseif segment.kind == "soft_hyphen" then
				last_break = {
					cursor = after_segment(cursor.segment_index),
					width = current_width + (segment.hyphen_width or prepared.hyphen_width or 0),
					soft_hyphen = true,
				}
				cursor = after_segment(cursor.segment_index)
			elseif segment.kind == "space" or segment.kind == "preserved_space" then
				current_width = current_width + (segment.width or 0)
				last_break = {
					cursor = after_segment(cursor.segment_index),
					width = has_content and current_width - (segment.width or 0) or 0,
					soft_hyphen = false,
				}
				cursor = after_segment(cursor.segment_index)
			elseif segment.kind == "tab" then
				local tab_width = get_tab_width(prepared, current_width)
				current_width = current_width + tab_width
				last_break = {
					cursor = after_segment(cursor.segment_index),
					width = has_content and current_width - tab_width or 0,
					soft_hyphen = false,
				}
				cursor = after_segment(cursor.segment_index)
			else
				local remaining_width = measure_partial(segment, cursor.grapheme_index, #segment.graphemes + 1)
				local next_width = current_width + remaining_width

				if next_width <= max_width then
					current_width = next_width
					has_content = true

					if segment.can_break_after then
						local next_segment = prepared.segments[cursor.segment_index + 1]

						if can_break_between(segment, next_segment) then
							last_break = {
								cursor = after_segment(cursor.segment_index),
								width = current_width,
								soft_hyphen = false,
							}
						end
					end

					cursor = after_segment(cursor.segment_index)
				else
					if last_break and cursor_less_than(start_cursor, last_break.cursor) then
						return build_line(
							clone_cursor(start_cursor),
							clone_cursor(last_break.cursor),
							last_break.width,
							last_break.soft_hyphen
						)
					end

					local available = math.max(0, max_width - current_width)
					local count, fitted_width = fit_segment_prefix(segment, available)

					if count and count > 0 then
						local end_cursor = {
							segment_index = cursor.segment_index,
							grapheme_index = cursor.grapheme_index + count,
						}
						return build_line(clone_cursor(start_cursor), end_cursor, current_width + fitted_width, false)
					end

					if not has_content and segment.graphemes and #segment.graphemes > 0 then
						local width = measure_partial(segment, cursor.grapheme_index, cursor.grapheme_index + 1)
						return build_line(
							clone_cursor(start_cursor),
							{
								segment_index = cursor.segment_index,
								grapheme_index = cursor.grapheme_index + 1,
							},
							width,
							false
						)
					end

					return build_line(clone_cursor(start_cursor), clone_cursor(cursor), current_width, false)
				end
			end
		end
	end
end

do
	local function append_segment_text(parts, segment, start_grapheme, end_grapheme)
		if
			segment.kind == "hard_break" or
			segment.kind == "zero_width_break" or
			segment.kind == "soft_hyphen"
		then
			return
		end

		if start_grapheme == 1 and end_grapheme > #segment.graphemes then
			parts[#parts + 1] = segment.text
			return
		end

		for i = start_grapheme, end_grapheme - 1 do
			parts[#parts + 1] = segment.graphemes[i]
		end
	end

	local function materialize_line(prepared, line)
		local parts = {}
		local trailing_trim_index = nil
		local cursor = {
			segment_index = line.start.segment_index,
			grapheme_index = line.start.grapheme_index,
		}

		while
			cursor.segment_index < line["end"].segment_index or
			(
				cursor.segment_index == line["end"].segment_index and
				cursor.grapheme_index < line["end"].grapheme_index
			)
		do
			local segment = prepared.segments[cursor.segment_index]

			if not segment then break end

			local start_grapheme = cursor.grapheme_index
			local end_grapheme = 1

			if segment.graphemes then end_grapheme = #segment.graphemes + 1 end

			if cursor.segment_index == line["end"].segment_index then
				end_grapheme = line["end"].grapheme_index
			end

			append_segment_text(parts, segment, start_grapheme, end_grapheme)

			if segment.collapsible and prepared.options.white_space ~= "pre-wrap" then
				trailing_trim_index = #parts
			elseif segment.kind ~= "zero_width_break" and segment.kind ~= "soft_hyphen" then
				trailing_trim_index = nil
			end

			cursor.segment_index = cursor.segment_index + 1
			cursor.grapheme_index = 1
		end

		if trailing_trim_index then
			for i = #parts, trailing_trim_index, -1 do
				parts[i] = nil
			end
		end

		if line.soft_hyphen then parts[#parts + 1] = "-" end

		return table.concat(parts)
	end

	function line_break.materialize_line_range(prepared, line)
		return {
			start = clone_cursor(line.start),
			["end"] = clone_cursor(line["end"]),
			width = line.width,
			soft_hyphen = line.soft_hyphen or false,
			text = materialize_line(prepared, line),
		}
	end

	function line_break.layout_next_line(prepared, start_cursor, max_width)
		local line = line_break.layout_next_line_range(prepared, start_cursor, max_width)

		if not line then return nil end

		return line_break.materialize_line_range(prepared, line)
	end
end

function line_break.walk_line_ranges(prepared, max_width, on_line)
	local cursor = {segment_index = 1, grapheme_index = 1}
	local count = 0

	while true do
		local line = line_break.layout_next_line_range(prepared, cursor, max_width)

		if not line then break end

		count = count + 1

		if on_line then on_line(line) end

		if
			line["end"].segment_index == cursor.segment_index and
			line["end"].grapheme_index == cursor.grapheme_index
		then
			break
		end

		cursor = normalize_line_start(prepared, line["end"])

		if not prepared.segments[cursor.segment_index] then break end
	end

	return count
end

function line_break.measure_line_stats(prepared, max_width)
	local max_line_width = 0
	local line_count = line_break.walk_line_ranges(prepared, max_width, function(line)
		max_line_width = math.max(max_line_width, line.width or 0)
	end)
	return {
		line_count = line_count,
		max_line_width = max_line_width,
	}
end

function line_break.layout_with_lines(prepared, max_width, line_height)
	local lines = {}
	local count = line_break.walk_line_ranges(prepared, max_width, function(line)
		lines[#lines + 1] = line_break.materialize_line_range(prepared, line)
	end)
	return {
		line_count = count,
		height = count * (line_height or prepared.line_height or 0),
		lines = lines,
	}
end

function line_break.count_lines(prepared, max_width)
	return line_break.walk_line_ranges(prepared, max_width)
end

function line_break.measure_natural_width(prepared)
	return line_break.measure_line_stats(prepared, math_huge).max_line_width
end

function line_break.cursor_to_text_index(prepared, cursor)
	if not cursor then return 1 end

	local segment = prepared.segments[cursor.segment_index]

	if not segment then return utf8.length(prepared.text or "") + 1 end

	local raw_start = segment.raw_start or 1
	local raw_stop = segment.raw_stop or raw_start

	if not segment.graphemes or #segment.graphemes == 0 then
		if cursor.grapheme_index and cursor.grapheme_index > 1 then return raw_stop end

		return raw_start
	end

	local offset = math.max(0, (cursor.grapheme_index or 1) - 1)
	return math.min(raw_start + offset, raw_stop)
end

return line_break
