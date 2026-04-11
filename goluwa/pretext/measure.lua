local utf8 = import("goluwa/utf8.lua")
local measure = library()

local function assert_measurer(measurer)
	if type(measurer) ~= "table" then
		error("pretext.prepare expected a measurer object")
	end

	local required = {
		"MeasureText",
		"GetLineHeight",
		"GetSpaceAdvance",
		"GetTabAdvance",
	}

	for i = 1, #required do
		local name = required[i]

		if type(measurer[name]) ~= "function" then
			error("pretext.prepare expected measurer:" .. name .. "(...)")
		end
	end
end

local function measure_text(measurer, text)
	local width, height = measurer:MeasureText(text)
	return width or 0, height or 0
end

local function get_space_width(measurer)
	return measurer:GetSpaceAdvance() or 0
end

local function measure_grapheme_prefixes(measurer, segment)
	local graphemes = segment.graphemes or utf8.to_list(segment.text)
	segment.graphemes = graphemes

	if #graphemes <= 1 then return nil end

	local prefixes = {}

	if type(measurer.MeasureGraphemes) == "function" then
		local measured = measurer:MeasureGraphemes(segment.text, graphemes)

		if measured and #measured == #graphemes then return measured end
	end

	local running = 0

	for i = 1, #graphemes do
		local grapheme = graphemes[i]
		local advance = nil

		if type(measurer.GetGlyphAdvance) == "function" then
			advance = measurer:GetGlyphAdvance(grapheme)
		end

		if advance == nil then advance = measure_text(measurer, grapheme) end

		running = running + advance
		prefixes[i] = running
	end

	return prefixes
end

local function measure_segment(measurer, segment, options, shared)
	segment.width = 0
	segment.height = shared.line_height
	segment.fit_width = 0
	segment.paint_width = 0
	segment.graphemes = nil

	if segment.kind == "hard_break" or segment.kind == "zero_width_break" then
		return
	end

	if segment.kind == "soft_hyphen" then
		segment.hyphen_width = shared.hyphen_width
		return
	end

	if segment.kind == "tab" then
		segment.space_width = shared.space_width
		segment.graphemes = {segment.text}
		return
	end

	segment.width, segment.height = measure_text(measurer, segment.text)
	segment.paint_width = segment.width
	segment.fit_width = segment.width
	segment.graphemes = utf8.to_list(segment.text)

	if segment.kind == "space" and options.white_space ~= "pre-wrap" then
		segment.fit_width = 0
	end

	if segment.kind == "preserved_space" and options.white_space ~= "pre-wrap" then
		segment.fit_width = 0
	end

	if segment.kind == "text" or segment.kind == "glue" then
		segment.prefix_widths = measure_grapheme_prefixes(measurer, segment)
		segment.breakable_inside = #segment.graphemes > 1
	end
end

function measure.prepare(analyzed, measurer, options)
	assert_measurer(measurer)
	options = options or analyzed.options or {}
	local line_height = measurer:GetLineHeight() or 0
	local shared = {
		line_height = line_height,
		space_width = get_space_width(measurer),
		select(1, measure_text(measurer, "-")),
	}
	shared.hyphen_width = shared[1] or 0
	shared[1] = nil

	for i = 1, #analyzed.segments do
		measure_segment(measurer, analyzed.segments[i], options, shared)
	end

	return {
		text = analyzed.text,
		options = options,
		segments = analyzed.segments,
		measurer = measurer,
		line_height = line_height,
		space_width = shared.space_width,
		hyphen_width = shared.hyphen_width,
	}
end

return measure
