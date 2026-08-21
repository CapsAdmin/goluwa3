local commands = import("goluwa/cli/commands.lua")
local vulkan_memory = import("goluwa/render/vulkan/internal/memory.lua")
local callstack = import("goluwa/debug/callstack.lua")

local function format_bytes(bytes)
	bytes = math.max(0, tonumber(bytes) or 0)

	if bytes >= 1024 * 1024 * 1024 then
		return string.format("%.2f GiB", bytes / 1024 / 1024 / 1024)
	end

	if bytes >= 1024 * 1024 then
		return string.format("%.2f MiB", bytes / 1024 / 1024)
	end

	if bytes >= 1024 then return string.format("%.2f KiB", bytes / 1024) end

	return string.format("%d B", bytes)
end

local function normalize_traceback(traceback)
	traceback = tostring(traceback or "unknown traceback")
	traceback = traceback:trim()

	if traceback == "" then return "unknown traceback" end

	return traceback
end

local function trim_traceback(traceback)
	traceback = normalize_traceback(traceback)
	local lines = callstack.format(traceback)

	if not lines[1] then return traceback end

	local start_index

	for i, line in ipairs(lines) do
		if line:find("goluwa/render/vulkan/internal/buffer.lua:", nil, true) then
			start_index = i

			break
		end
	end

	if not start_index then
		for i, line in ipairs(lines) do
			if line:find("goluwa/render/vulkan/internal/image.lua:", nil, true) then
				start_index = i

				break
			end
		end
	end

	if not start_index then
		for i, line in ipairs(lines) do
			if line:find("goluwa/render/vulkan/internal/", nil, true) then
				start_index = i

				break
			end
		end
	end

	if not start_index then return traceback end

	local end_index = #lines

	for i = start_index, #lines do
		if lines[i]:find("main.lua:", nil, true) then
			end_index = i

			break
		end
	end

	local out = {}

	for i = start_index, end_index do
		list.insert(out, lines[i])

		if i ~= end_index and lines[i] == "stack traceback:" then
			list.insert(out, "")
		end
	end

	if not out[1] then return traceback end

	return table.concat(out, "\n")
end

local function indent_traceback(traceback)
	local out = {}

	for _, line in ipairs(traceback:split("\n")) do
		list.insert(out, "  " .. line)
	end

	return table.concat(out, "\n")
end

commands.Add("dump_vulkan_memory=number[20]", function(limit)
	limit = math.max(1, math.floor(tonumber(limit) or 20))
	local total_bytes = 0
	local allocation_count = 0
	local freed_count = tonumber(vulkan_memory.total_freed_count) or 0
	local freed_bytes = tonumber(vulkan_memory.total_freed_bytes) or 0
	local hotspots = {}

	for _, allocation in pairs(vulkan_memory.Instances) do
		if allocation and allocation.size then
			local size = tonumber(allocation.size) or 0
			local traceback = trim_traceback(allocation.traceback)
			local hotspot = hotspots[traceback]

			if not hotspot then
				hotspot = {
					traceback = traceback,
					count = 0,
					bytes = 0,
				}
				hotspots[traceback] = hotspot
			end

			hotspot.count = hotspot.count + 1
			hotspot.bytes = hotspot.bytes + size
			total_bytes = total_bytes + size
			allocation_count = allocation_count + 1
		end
	end

	local sorted = {}

	for _, hotspot in pairs(hotspots) do
		list.insert(sorted, hotspot)
	end

	table.sort(sorted, function(a, b)
		if a.bytes ~= b.bytes then return a.bytes > b.bytes end

		if a.count ~= b.count then return a.count > b.count end

		return a.traceback < b.traceback
	end)

	logn(
		string.format(
			"Live Vulkan memory allocations: %d objects, %s total | Freed: %d objects, %s total",
			allocation_count,
			format_bytes(total_bytes),
			freed_count,
			format_bytes(freed_bytes)
		)
	)

	if #sorted == 0 then
		logn("No live Vulkan memory allocations tracked.")
		return
	end

	logn(string.format("Top %d Vulkan memory hotspots:", math.min(limit, #sorted)))

	for i = 1, math.min(limit, #sorted) do
		local hotspot = sorted[i]
		logn(
			string.format(
				"[%d] %s across %d allocations",
				i,
				format_bytes(hotspot.bytes),
				hotspot.count
			)
		)
		logn(indent_traceback(hotspot.traceback))
	end
end)
