local T = import("test/environment.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local ttf_font = import("goluwa/render2d/fonts/ttf.lua")
local pretext = import("goluwa/pretext/init.lua")

local mock_measurer = {
	MeasureText = function(_, text)
		return text:utf8_length() * 8, 8
	end,
	GetLineHeight = function()
		return 8
	end,
	GetSpaceAdvance = function()
		return 8
	end,
	GetTabAdvance = function(_, space_width, tab_size)
		return (space_width or 8) * (tab_size or 4)
	end,
	GetGlyphAdvance = function()
		return 8
	end,
}

local function split_lines(str)
	local lines = {}

	for line in (tostring(str or "") .. "\n"):gmatch("(.-)\n") do
		lines[#lines + 1] = line
	end

	if #lines == 0 then lines[1] = tostring(str or "") end

	return lines
end

T.Test("pretext wraps words with deterministic metrics", function()
	local wrapped = pretext.wrap_text("hello world again", 40, mock_measurer)
	T(wrapped)["=="]("hello\nworld\nagain")
end)

T.Test("pretext preserves explicit hard breaks", function()
	local wrapped = pretext.wrap_text("abc\ndef ghi", 24, mock_measurer)
	T(wrapped)["=="]("abc\ndef\nghi")
end)

T.Test("pretext breaks oversized tokens", function()
	local wrapped = pretext.wrap_text("abcdefgh", 16, mock_measurer)
	T(wrapped)["=="]("ab\ncd\nef\ngh")
end)

T.Test("pretext layout_with_lines returns stable widths", function()
	local prepared = pretext.prepare("hello world again", mock_measurer)
	local result = pretext.layout_with_lines(prepared, 40, 8)
	T(result.line_count)["=="](3)
	T(result.lines[1].text)["=="]("hello")
	T(result.lines[2].text)["=="]("world")
	T(result.lines[3].text)["=="]("again")
	T(result.lines[1].width)["=="](40)
	T(result.lines[2].width)["=="](40)
	T(result.lines[3].width)["=="](40)
	T(result.height)["=="](24)
end)

T.Test("pretext walk_line_ranges exposes cheap line geometry", function()
	local prepared = pretext.prepare("hello world again", mock_measurer)
	local widths = {}
	local texts = {}
	local count = pretext.walk_line_ranges(prepared, 40, function(line)
		widths[#widths + 1] = line.width
		texts[#texts + 1] = pretext.materialize_line_range(prepared, line).text
	end)

	T(count)["=="](3)
	T(widths[1])["=="](40)
	T(widths[2])["=="](40)
	T(widths[3])["=="](40)
	T(texts[1])["=="]("hello")
	T(texts[2])["=="]("world")
	T(texts[3])["=="]("again")
end)

T.Test("pretext measure_line_stats matches wrapped geometry", function()
	local prepared = pretext.prepare("hello world again", mock_measurer)
	local stats = pretext.measure_line_stats(prepared, 40)
	T(stats.line_count)["=="](3)
	T(stats.max_line_width)["=="](40)
	T(pretext.measure_natural_width(prepared))["=="](select(1, mock_measurer:MeasureText("hello world again")))
end)

T.Test("pretext wraps vector ttf fonts", function()
	local path = fonts.GetDefaultSystemFontPath()

	if not path then return T.Unavailable("system font path unavailable") end

	local font = ttf_font.New(path)
	font:SetSize(16)
	local wrapped = font:WrapString("hello world again", select(1, font:GetTextSize("hello world")))
	local lines = split_lines(wrapped)
	assert(#lines >= 2, "expected vector font wrapping to produce at least two lines")
	assert(lines[1] == "hello" or lines[1] == "hello world", "unexpected first wrapped line: " .. tostring(lines[1]))
	assert(lines[#lines] == "again" or lines[#lines] == "world again", "unexpected last wrapped line: " .. tostring(lines[#lines]))
	for i = 1, #lines do
		local width = select(1, font:GetTextSize(lines[i]))
		assert(width <= select(1, font:GetTextSize("hello world")), "wrapped line exceeded requested width")
	end
end)