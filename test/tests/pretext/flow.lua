local T = import("test/environment.lua")
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

T.Test("pretext flow matches normal layout without obstacles", function()
	local prepared = pretext.prepare("hello world again", mock_measurer)
	local wrapped = pretext.layout_with_lines(prepared, 40, 8)
	local flowed = pretext.layout_flow(prepared, {x = 0, y = 0, width = 40, height = 64}, 8, {}, {use_all_slots = false})

	T(#flowed.lines)["=="](#wrapped.lines)

	for i = 1, #wrapped.lines do
		T(flowed.lines[i].text)["=="](wrapped.lines[i].text)
		T(flowed.lines[i].x)["=="](0)
		T(flowed.lines[i].y)["=="]((i - 1) * 8)
	end

	T(flowed.done)["=="](true)
end)

T.Test("pretext flow routes lines around a rectangle", function()
	local prepared = pretext.prepare("aa bb cc dd ee ff", mock_measurer)
	local layout = pretext.layout_flow(
		prepared,
		{x = 0, y = 0, width = 80, height = 64},
		8,
		{{kind = "rect", x = 24, y = 0, width = 32, height = 16}},
		{min_slot_width = 16, use_all_slots = true}
	)

	T(layout.lines[1].x)["=="](0)
	T(layout.lines[2].x)["=="](56)
	T(layout.lines[1].band_index)["=="](1)
	T(layout.lines[2].band_index)["=="](1)
	T(layout.lines[3].band_index)["=="](2)
	T(layout.lines[3].x)["=="](0)
	assert(#layout.lines >= 4, "expected multiple routed line fragments")
end)

T.Test("pretext flow computes circle intervals per band", function()
	local intervals = pretext.get_obstacle_intervals(
		{{kind = "circle", cx = 40, cy = 20, radius = 10}},
		16,
		24
	)

	T(#intervals)["=="](1)
	assert(intervals[1].left < 40, "circle interval should extend left of center")
	assert(intervals[1].right > 40, "circle interval should extend right of center")
	assert(intervals[1].right - intervals[1].left > 0, "circle interval should have width")
end)