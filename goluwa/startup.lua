local get_time = import("goluwa/bindings/time.lua")
local startup = {}
local origin = get_time()
local spans = {}
local open = {}
local marks = {}
local totals = {}
local total_list = {}
startup.ready_time = nil

function startup.GetTime()
	return get_time() - origin
end

function startup.Begin(name)
	local span = {name = name, start = get_time() - origin}
	spans[#spans + 1] = span
	local stack = open[name]

	if not stack then
		stack = {}
		open[name] = stack
	end

	stack[#stack + 1] = span
	return span
end

function startup.End(name)
	local stack = open[name]
	local span = stack[#stack]
	stack[#stack] = nil
	span.stop = get_time() - origin
	return span.stop - span.start
end

function startup.Mark(name)
	marks[#marks + 1] = {name = name, time = get_time() - origin}
end

function startup.Start()
	return get_time()
end

function startup.Add(name, started)
	if startup.ready_time then return end

	local total = totals[name]

	if not total then
		total = {name = name, seconds = 0, count = 0, first = get_time() - origin}
		totals[name] = total
		total_list[#total_list + 1] = total
	end

	local now = get_time()
	local delta = now - started
	total.seconds = total.seconds + delta
	total.count = total.count + 1

	if delta > (total.max or 0) then total.max = delta end

	total.last = now - origin
end

function startup.SetReady(time, snapshot)
	if startup.ready_time then return end

	startup.ready_time = time or get_time() - origin
	marks[#marks + 1] = {name = "ready", time = startup.ready_time}

	if snapshot then
		for _, total in ipairs(total_list) do
			local at_ready = snapshot[total.name]

			if at_ready then
				total.seconds = at_ready.seconds
				total.count = at_ready.count
				total.last = at_ready.last
			else
				total.seconds = 0
				total.count = 0
				total.hidden = true
			end
		end
	end
end

function startup.Snapshot()
	local snapshot = {}

	for _, total in ipairs(total_list) do
		snapshot[total.name] = {seconds = total.seconds, count = total.count, last = total.last}
	end

	return snapshot
end

function startup.IsReady()
	return startup.ready_time ~= nil
end

function startup.GetMarks()
	return marks
end

function startup.GetTotals()
	return total_list
end

local function by_start(a, b)
	if a.start ~= b.start then return a.start < b.start end

	if a.stop ~= b.stop then return a.stop > b.stop end

	return a.order < b.order
end

function startup.GetTree()
	local now = get_time() - origin
	local list = {}

	for i, span in ipairs(spans) do
		list[i] = {
			name = span.name,
			start = span.start,
			stop = span.stop or now,
			running = not span.stop,
			order = i,
		}
	end

	table.sort(list, by_start)
	local stack = {}

	for _, span in ipairs(list) do
		while stack[#stack] and stack[#stack].stop <= span.start do
			stack[#stack] = nil
		end

		span.depth = #stack
		span.parent = stack[#stack]
		stack[#stack + 1] = span
	end

	return list
end

local function by_seconds(a, b)
	return a.seconds > b.seconds
end

function startup.GetReport()
	local lines = {}
	local tree = startup.GetTree()

	for _, span in ipairs(tree) do
		lines[#lines + 1] = string.format(
			"%8.3f %8.3f  %s%s%s",
			span.start,
			span.stop - span.start,
			string.rep("  ", span.depth),
			span.name,
			span.running and " (running)" or ""
		)
	end

	if total_list[1] then
		lines[#lines + 1] = ""
		table.sort(total_list, by_seconds)

		for _, total in ipairs(total_list) do
			if not total.hidden then
				lines[#lines + 1] = string.format(
					"  %-40s %8.3f s  x%-6d  avg %7.3f ms  max %7.3f ms  %6.2f..%6.2f",
					total.name,
					total.seconds,
					total.count,
					total.seconds / total.count * 1000,
					total.max * 1000,
					total.first,
					total.last
				)
			end
		end
	end

	if startup.ready_time then
		lines[#lines + 1] = string.format("\nready after %.3f s", startup.ready_time)
	end

	return table.concat(lines, "\n")
end

return startup
