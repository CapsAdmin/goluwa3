-- Toggleable statistics for the rigid body pipeline. Off by default; enable
-- with stats:Enable() and read the accumulated overview with stats:Summary().
-- Sections are measured with a PushTime/PopTime stack, counters accumulate
-- across steps (reported as totals with per-step averages) and gauges keep
-- the most recent value of a metric like the live body count.
local system = import("goluwa/system.lua")
local stats = {}
local STEP_SECTION = "step"
local section_names = {
	"synchronize",
	"integrate",
	"broadphase",
	"islands",
	"ccd",
	"solve_pairs",
	"support",
	"constraints",
	"velocities_sleep",
	"finalize",
}
local BUCKET_EDGES_MS = {1, 4, 8, 16, 32}
local BUCKET_LABELS = {"<1ms", "1-4ms", "4-8ms", "8-16ms", "16-32ms", ">32ms"}
local state = nil

function stats:Enable()
	state = {
		steps = 0,
		total_time = 0,
		min_step_time = math.huge,
		max_step_time = 0,
		stack = {},
		stack_depth = 0,
		sections = {},
		counts = {},
		gauges = {},
		buckets = {},
	}

	for i = 1, #section_names do
		state.sections[section_names[i]] = 0
	end
end

function stats:Disable()
	state = nil
end

function stats:IsEnabled()
	return state ~= nil
end

function stats:Reset()
	if not state then return end

	state.steps = 0
	state.total_time = 0
	state.min_step_time = math.huge
	state.max_step_time = 0
	state.stack_depth = 0

	for i = 1, #section_names do
		state.sections[section_names[i]] = 0
	end

	state.counts = {}
	state.gauges = {}
	state.buckets = {}
end

-- push a section onto the stack; the start time is captured last so the cost
-- of pushing itself is not counted in the measured section
function stats:PushTime(name)
	if not state then return end

	local stack = state.stack
	local depth = state.stack_depth + 1
	local entry = stack[depth]

	if not entry then
		entry = {}
		stack[depth] = entry
	end

	entry.name = name
	state.stack_depth = depth
	entry.t0 = system.GetTime()
end

-- pop the section pushed last and accumulate its elapsed time into its
-- bucket; the end time is captured first for the same reason
function stats:PopTime()
	if not state then return end

	local entry = state.stack[state.stack_depth]
	local elapsed = system.GetTime() - entry.t0
	state.stack_depth = state.stack_depth - 1

	if entry.name == STEP_SECTION then
		state.steps = state.steps + 1
		state.total_time = state.total_time + elapsed

		if elapsed < state.min_step_time then state.min_step_time = elapsed end

		if elapsed > state.max_step_time then state.max_step_time = elapsed end

		local ms = elapsed * 1000
		local bucket = #BUCKET_EDGES_MS + 1

		for i = 1, #BUCKET_EDGES_MS do
			if ms < BUCKET_EDGES_MS[i] then
				bucket = i

				break
			end
		end

		local buckets = state.buckets
		buckets[bucket] = (buckets[bucket] or 0) + 1
		return
	end

	state.sections[entry.name] = (state.sections[entry.name] or 0) + elapsed
end

-- accumulate a delta into a counter
function stats:Count(name, amount)
	if not state then return end

	state.counts[name] = (state.counts[name] or 0) + (amount or 1)
end

-- store the current value of a metric (last write wins)
function stats:Gauge(name, value)
	if not state then return end

	state.gauges[name] = value
end

local function format_line(label, value, total)
	local percent = total > 0 and (value / total) * 100 or 0
	return string.format("    %-16s %8.3f ms  %5.1f%%", label, value * 1000, percent)
end

function stats:Summary()
	if not state or state.steps == 0 then return "" end

	local steps = state.steps
	local total = state.total_time
	local out = {
		string.format(
			"physics stats: %d steps in %.3f ms (%.3f ms/step avg, %.3f min, %.3f max)",
			steps,
			total * 1000,
			(total / steps) * 1000,
			state.min_step_time * 1000,
			state.max_step_time * 1000
		),
	}
	local section_sum = 0

	for i = 1, #section_names do
		section_sum = section_sum + state.sections[section_names[i]]
	end

	out[#out + 1] = string.format(
		"sections:      %.1f%% of step time accounted for",
		total > 0 and (section_sum / total) * 100 or 0
	)
	local bucket_parts = {}

	for i, label in ipairs(BUCKET_LABELS) do
		bucket_parts[#bucket_parts + 1] = string.format("%s: %d", label, state.buckets[i] or 0)
	end

	out[#out + 1] = "step buckets:  " .. table.concat(bucket_parts, "  ")
	local total_ms = total * 1000
	local cost_parts = {}
	local pair_iterations = state.counts["solver_pairs"]

	if pair_iterations then
		cost_parts[#cost_parts + 1] = string.format("%.2f ms/1k pair iterations", total_ms * 1000 / pair_iterations)
	end

	local contact_rebuilds = state.counts["contact_points"]

	if contact_rebuilds then
		cost_parts[#cost_parts + 1] = string.format("%.3f ms/100 contact rebuilds", total_ms * 100 / contact_rebuilds)
	end

	if #cost_parts > 0 then
		out[#out + 1] = "cost:          " .. table.concat(cost_parts, "  ")
	end

	for i = 1, #section_names do
		local name = section_names[i]
		out[#out + 1] = format_line(name, state.sections[name], total)
	end

	local gauge_names = {}

	for name in pairs(state.gauges) do
		gauge_names[#gauge_names + 1] = name
	end

	table.sort(gauge_names)

	if #gauge_names > 0 then
		local parts = {}

		for i = 1, #gauge_names do
			local name = gauge_names[i]
			parts[#parts + 1] = string.format("%s=%d", name, state.gauges[name])
		end

		out[#out + 1] = "gauges (last): " .. table.concat(parts, "  ")
	end

	local counter_names = {}

	for name in pairs(state.counts) do
		counter_names[#counter_names + 1] = name
	end

	table.sort(counter_names, function(a, b)
		return state.counts[a] > state.counts[b]
	end)

	if #counter_names > 0 then
		out[#out + 1] = "counters (total, avg/step):"

		for i = 1, #counter_names do
			local name = counter_names[i]
			local value = state.counts[name]
			out[#out + 1] = string.format("    %-24s %12d %10.3f", name, value, value / steps)
		end
	end

	return table.concat(out, "\n")
end

return stats
