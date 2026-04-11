local utf8 = import("goluwa/utf8.lua")
local analysis = library()

local function flush_text(segments, buffer, raw_start, raw_stop)
	if #buffer == 0 then return end

	segments[#segments + 1] = {
		kind = "text",
		text = table.concat(buffer),
		raw_start = raw_start,
		raw_stop = raw_stop,
	}

	for i = #buffer, 1, -1 do
		buffer[i] = nil
	end
end

local function add_segment(segments, segment)
	segments[#segments + 1] = segment
	return segment
end

local function trim_collapsible_spaces(segments)
	local trimmed = {}
	local pending_space = false

	for i = 1, #segments do
		local segment = segments[i]

		if segment.kind == "space" then
			pending_space = #trimmed > 0 and trimmed[#trimmed].kind ~= "hard_break"
		elseif segment.kind == "hard_break" then
			pending_space = false
			trimmed[#trimmed + 1] = segment
		else
			if pending_space then
				trimmed[#trimmed + 1] = {kind = "space", text = " ", collapsible = true, can_break_after = true}
				pending_space = false
			end

			trimmed[#trimmed + 1] = segment
		end
	end

	return trimmed
end

function analysis.normalize_options(options)
	options = options or {}
	return {
		white_space = options.white_space or options.whiteSpace or "normal",
		word_break = options.word_break or options.wordBreak or "normal",
		tab_size = options.tab_size or options.tabSize or 4,
		trim_trailing_spaces = options.trim_trailing_spaces,
	}
end

function analysis.analyze(text, options)
	options = analysis.normalize_options(options)
	text = tostring(text or "")
	local segments = {}
	local buffer = {}
	local graphemes = utf8.to_list(text)
	local white_space = options.white_space
	local previous_was_space = false
	local buffer_start = nil

	for i = 1, #graphemes do
		local char = graphemes[i]

		if char == "\r" then
			if graphemes[i + 1] ~= "\n" then
				flush_text(segments, buffer, buffer_start, i)
				buffer_start = nil
				add_segment(
					segments,
					{
						kind = "hard_break",
						text = "\n",
						forced = true,
						raw_start = i,
						raw_stop = i + 1,
					}
				)
				previous_was_space = false
			end
		elseif char == "\n" then
			flush_text(segments, buffer, buffer_start, i)
			buffer_start = nil
			add_segment(
				segments,
				{
					kind = "hard_break",
					text = "\n",
					forced = true,
					raw_start = i,
					raw_stop = i + 1,
				}
			)
			previous_was_space = false
		elseif char == "\t" then
			flush_text(segments, buffer, buffer_start, i)
			buffer_start = nil

			if white_space == "pre-wrap" then
				add_segment(
					segments,
					{
						kind = "tab",
						text = "\t",
						can_break_after = true,
						collapsible = false,
						raw_start = i,
						raw_stop = i + 1,
					}
				)
			else
				if not previous_was_space then
					add_segment(
						segments,
						{
							kind = "space",
							text = " ",
							collapsible = true,
							can_break_after = true,
							raw_start = i,
							raw_stop = i + 1,
						}
					)
				end
			end

			previous_was_space = true
		elseif char == " " then
			flush_text(segments, buffer, buffer_start, i)
			buffer_start = nil

			if white_space == "pre-wrap" then
				add_segment(
					segments,
					{
						kind = "preserved_space",
						text = char,
						collapsible = false,
						can_break_after = true,
						raw_start = i,
						raw_stop = i + 1,
					}
				)
			else
				if not previous_was_space then
					add_segment(
						segments,
						{
							kind = "space",
							text = " ",
							collapsible = true,
							can_break_after = true,
							raw_start = i,
							raw_stop = i + 1,
						}
					)
				end
			end

			previous_was_space = true
		elseif utf8.is_glue(char) then
			flush_text(segments, buffer, buffer_start, i)
			buffer_start = nil
			add_segment(
				segments,
				{
					kind = "glue",
					text = char,
					can_break_after = false,
					collapsible = false,
					raw_start = i,
					raw_stop = i + 1,
				}
			)
			previous_was_space = false
		elseif utf8.is_zero_width_break(char) then
			flush_text(segments, buffer, buffer_start, i)
			buffer_start = nil
			add_segment(
				segments,
				{
					kind = "zero_width_break",
					text = "",
					can_break_after = true,
					collapsible = false,
					raw_start = i,
					raw_stop = i + 1,
				}
			)
			previous_was_space = false
		elseif utf8.is_soft_hyphen(char) then
			flush_text(segments, buffer, buffer_start, i)
			buffer_start = nil
			add_segment(
				segments,
				{
					kind = "soft_hyphen",
					text = "",
					visible_text = "-",
					can_break_after = true,
					collapsible = false,
					raw_start = i,
					raw_stop = i + 1,
				}
			)
			previous_was_space = false
		elseif utf8.is_cjk(char) then
			flush_text(segments, buffer, buffer_start, i)
			buffer_start = nil
			add_segment(
				segments,
				{
					kind = "text",
					text = char,
					is_cjk = true,
					can_break_after = not utf8.is_kinsoku_end(char),
					forbid_line_start = utf8.is_kinsoku_start(char),
					forbid_line_end = utf8.is_kinsoku_end(char),
					raw_start = i,
					raw_stop = i + 1,
				}
			)
			previous_was_space = false
		else
			if not buffer_start then buffer_start = i end

			buffer[#buffer + 1] = char
			previous_was_space = false
		end
	end

	flush_text(segments, buffer, buffer_start, #graphemes + 1)

	if white_space ~= "pre-wrap" then
		segments = trim_collapsible_spaces(segments)
	end

	return {
		text = text,
		options = options,
		segments = segments,
	}
end

return analysis
