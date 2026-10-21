if not RENDER_2D then return end

local Vec2 = import("goluwa/structs/vec2.lua")
local commands = import("goluwa/cli/commands.lua")
local startup = import("goluwa/startup.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local perf = import("lua/perf.lua")

local function format_seconds(seconds)
	if seconds >= 1 then return string.format("%.2f s", seconds) end

	return string.format("%.0f ms", seconds * 1000)
end

local MAX_SPAN_DEPTH = 2
local MAX_GROUP_CHILDREN = 4
local MIN_SPAN_FRACTION = 0.015
local WINDOW = 0.25

local function by_seconds(a, b)
	return a.seconds > b.seconds
end

local function add_entry(rows, total, label, seconds, first, last, color)
	rows[#rows + 1] = {
		label = label,
		value = format_seconds(seconds),
		offset = first / total,
		fraction = math.max(math.min(last, total) - first, 0) / total,
		color = color,
	}
end

local function get_rows()
	local now = startup.GetTime()
	local total = startup.ready_time or now
	local rows = {
		{
			label = startup.ready_time and
				string.format("scene ready after %s", format_seconds(startup.ready_time)) or
				string.format("loading, %s so far", format_seconds(now)),
			color = startup.ready_time and "head" or "warn",
		},
		{label = "timeline", color = "head"},
	}
	local tree = startup.GetTree()
	local last_stop = 0

	for _, span in ipairs(tree) do
		if not span.running and span.stop > last_stop then last_stop = span.stop end

		if
			span.depth <= MAX_SPAN_DEPTH and
			span.start < total and
			(
				span.depth == 0 or
				span.stop - span.start >= total * MIN_SPAN_FRACTION
			)
		then
			local stop = math.min(span.stop, total)
			rows[#rows + 1] = {
				label = string.rep("  ", span.depth) .. span.name,
				value = format_seconds(span.stop - span.start),
				offset = span.start / total,
				fraction = (stop - span.start) / total,
				color = span.depth == 0 and "default" or "dim",
			}
		end
	end

	if startup.ready_time and startup.ready_time - last_stop > total * MIN_SPAN_FRACTION then
		add_entry(
			rows,
			total,
			"until ready (streaming, first frames)",
			startup.ready_time - last_stop,
			last_stop,
			total,
			"warn"
		)
	end

	rows[#rows + 1] = {
		label = "main thread work, adds up many small pieces, overlaps the above",
		color = "head",
	}
	local groups = {}
	local group_list = {}
	local singles = {}

	for _, entry in ipairs(startup.GetTotals()) do
		if not entry.hidden and entry.count > 0 then
			local group_name = entry.name:match("^(.-): ")

			if group_name then
				local group = groups[group_name]

				if not group then
					group = {name = group_name, seconds = 0, count = 0, children = {}}
					groups[group_name] = group
					group_list[#group_list + 1] = group
				end

				group.seconds = group.seconds + entry.seconds
				group.count = group.count + entry.count
				group.first = math.min(group.first or entry.first, entry.first)
				group.last = math.max(group.last or entry.last, entry.last)
				group.children[#group.children + 1] = entry
			else
				singles[#singles + 1] = entry
			end
		end
	end

	local items = {}

	for _, group in ipairs(group_list) do
		items[#items + 1] = {seconds = group.seconds, group = group}
	end

	for _, entry in ipairs(singles) do
		items[#items + 1] = {seconds = entry.seconds, entry = entry}
	end

	table.sort(items, by_seconds)

	for _, item in ipairs(items) do
		if item.group then
			local group = item.group
			add_entry(
				rows,
				total,
				group.name,
				group.seconds,
				group.first,
				group.last,
				"default"
			)
			table.sort(group.children, by_seconds)

			for i = 1, math.min(#group.children, MAX_GROUP_CHILDREN) do
				local child = group.children[i]
				add_entry(
					rows,
					total,
					string.format("  %s  x%d", child.name:sub(#group.name + 3), child.count),
					child.seconds,
					child.first,
					child.last,
					"dim"
				)
			end

			if #group.children > MAX_GROUP_CHILDREN then
				rows[#rows + 1] = {
					label = string.format("  +%d more", #group.children - MAX_GROUP_CHILDREN),
					color = "dim",
				}
			end
		else
			local entry = item.entry
			add_entry(
				rows,
				total,
				string.format("%s  x%d", entry.name, entry.count),
				entry.seconds,
				entry.first,
				entry.last,
				"default"
			)
		end
	end

	return rows
end

local ready_rows

local function poll_rows()
	if ready_rows then return ready_rows end

	local rows = get_rows()

	if startup.ready_time then ready_rows = rows end

	return rows
end

perf.RegisterTab(
	"STARTUP",
	9,
	react.Component(
		||->ui.StatTable{Size = Vec2(660, 430), Timeline = true, Rows = react.UsePoll(poll_rows, WINDOW)}
	)
)

commands.Add("startup_stats", function()
	perf.PrintRows(get_rows())
end)
