local analysis = import("goluwa/pretext/analysis.lua")
local measure = import("goluwa/pretext/measure.lua")
local line_break = import("goluwa/pretext/line_break.lua")
local flow = import("goluwa/pretext/flow.lua")
local pretext = library()

function pretext.prepare(text, measurer, options)
	local normalized = analysis.normalize_options(options)
	local analyzed = analysis.analyze(text, normalized)
	return measure.prepare(analyzed, measurer, normalized)
end

function pretext.layout(prepared, max_width, line_height)
	local line_count = line_break.count_lines(prepared, max_width)
	line_height = line_height or prepared.line_height or 0
	return {line_count = line_count, height = line_count * line_height}
end

function pretext.layout_with_lines(prepared, max_width, line_height)
	return line_break.layout_with_lines(prepared, max_width, line_height)
end

function pretext.layout_next_line(prepared, start_cursor, max_width)
	return line_break.layout_next_line(prepared, start_cursor, max_width)
end

function pretext.layout_next_line_range(prepared, start_cursor, max_width)
	return line_break.layout_next_line_range(prepared, start_cursor, max_width)
end

function pretext.materialize_line_range(prepared, line)
	return line_break.materialize_line_range(prepared, line)
end

function pretext.walk_line_ranges(prepared, max_width, on_line)
	return line_break.walk_line_ranges(prepared, max_width, on_line)
end

function pretext.measure_line_stats(prepared, max_width)
	return line_break.measure_line_stats(prepared, max_width)
end

function pretext.measure_natural_width(prepared)
	return line_break.measure_natural_width(prepared)
end

function pretext.cursor_to_text_index(prepared, cursor)
	return line_break.cursor_to_text_index(prepared, cursor)
end

function pretext.layout_flow(prepared, region, line_height, obstacles, options)
	return flow.layout(prepared, region, line_height, obstacles, options)
end

function pretext.get_obstacle_intervals(obstacles, band_top, band_bottom)
	return flow.get_obstacle_intervals(obstacles, band_top, band_bottom)
end

function pretext.carve_text_line_slots(base, blocked, min_width)
	return flow.carve_text_line_slots(base, blocked, min_width)
end

function pretext.wrap_text(text, max_width, measurer, options)
	local prepared = pretext.prepare(text, measurer, options)
	local result = pretext.layout_with_lines(prepared, max_width, prepared.line_height)
	local lines = {}

	for i = 1, #result.lines do
		lines[i] = result.lines[i].text
	end

	return table.concat(lines, "\n"), result, prepared
end

function pretext.wrap_font_text(font, text, max_width, options)
	return pretext.wrap_text(text, max_width, font, options)
end

function pretext.clear_cache()
	return nil
end

return pretext
