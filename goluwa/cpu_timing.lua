local get_time = import("goluwa/bindings/time.lua")
local cpu_timing = {}
cpu_timing.enabled = false
local depth = 0
local starts = {}
local children = {}
local users = 0

function cpu_timing.Enable()
	users = users + 1
	cpu_timing.enabled = true
end

function cpu_timing.Disable()
	users = users - 1
	cpu_timing.enabled = users > 0
end

function cpu_timing.Reset()
	depth = 0
end

function cpu_timing.Begin()
	depth = depth + 1
	children[depth] = 0
	starts[depth] = get_time()
end

function cpu_timing.End(record)
	local elapsed = get_time() - starts[depth]
	record.cpu_time = (record.cpu_time or 0) + elapsed - children[depth]
	record.cpu_calls = (record.cpu_calls or 0) + 1
	depth = depth - 1

	if depth > 0 then children[depth] = children[depth] + elapsed end
end

return cpu_timing
