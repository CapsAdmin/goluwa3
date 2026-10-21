local commands = import("goluwa/cli/commands.lua")
local vulkan_memory = import("goluwa/render/vulkan/internal/memory.lua")
local callstack = import("goluwa/debug/callstack.lua")

do
	if not RENDER_2D then return end

	local commands = import("goluwa/cli/commands.lua")
	local Vec2 = import("goluwa/structs/vec2.lua")
	local render = import("goluwa/render/render.lua")
	local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
	local vulkan_memory = import("goluwa/render/vulkan/internal/memory.lua")
	local react = import("goluwa/render2d/ui/react.lua")
	local ui = import("goluwa/render2d/ui/react_ui.lua")
	local perf = import("lua/perf.lua")
	local WINDOW = 0.5
	local MAX_ROWS = 20

	local function format_bytes(bytes)
		if bytes >= 1024 * 1024 * 1024 then
			return string.format("%.2f GiB", bytes / 1024 / 1024 / 1024)
		end

		return string.format("%.1f MiB", bytes / 1024 / 1024)
	end

	local function by_bytes(a, b)
		if a.bytes ~= b.bytes then return a.bytes > b.bytes end

		return a.label < b.label
	end

	local function get_device_heap_bytes()
		local properties = vulkan.vk.VkPhysicalDeviceMemoryProperties()
		vulkan.lib.vkGetPhysicalDeviceMemoryProperties(render.GetDevice().physical_device.ptr[0], properties)
		local total = 0

		for i = 0, properties.memoryHeapCount - 1 do
			if bit.band(properties.memoryHeaps[i].flags, 1) ~= 0 then
				total = total + tonumber(properties.memoryHeaps[i].size)
			end
		end

		return total
	end

	local function take_pending_groups()
		local sorted = {}

		for label, bytes in pairs(vulkan_memory.pending_release_by_name) do
			sorted[#sorted + 1] = {label = label, bytes = bytes}
		end

		table.sort(sorted, by_bytes)
		return sorted
	end

	local function take_snapshot()
		local groups = {}
		local total = 0
		local count = 0

		for _, memory in pairs(vulkan_memory.Instances) do
			if memory:IsValid() then
				local label = (
						memory.debug_name and
						memory.debug_name:gsub(" memory$", "") or
						"(unnamed)"
					) .. (
						" [type " .. memory.type_index .. "]"
					)
				local group = groups[label]

				if not group then
					group = {label = label, bytes = 0, count = 0}
					groups[label] = group
				end

				local size = tonumber(memory.size)
				group.bytes = group.bytes + size
				group.count = group.count + 1
				total = total + size
				count = count + 1
			end
		end

		local sorted = {}

		for _, group in pairs(groups) do
			sorted[#sorted + 1] = group
		end

		table.sort(sorted, by_bytes)
		return {
			groups = sorted,
			total = total,
			count = count,
			heap = get_device_heap_bytes(),
			pending = vulkan_memory.pending_release_bytes,
			pending_groups = take_pending_groups(),
		}
	end

	local function build_rows(s)
		local fraction = s.heap > 0 and s.total / s.heap or 0
		local rows = {
			{
				label = string.format(
					"vram  %s of %s device local (%.0f%%)  %d allocations  +%s awaiting release",
					format_bytes(s.total),
					format_bytes(s.heap),
					fraction * 100,
					s.count,
					format_bytes(s.pending)
				),
				color = fraction > 0.9 and "warn" or "head",
			},
		}

		for i = 1, math.min(MAX_ROWS, #s.groups) do
			local group = s.groups[i]
			rows[#rows + 1] = {
				label = group.label,
				value = format_bytes(group.bytes),
				detail = "x" .. group.count,
				fraction = group.bytes / s.groups[1].bytes,
				color = i == 1 and "head" or nil,
			}
		end

		if #s.groups > MAX_ROWS then
			local rest = 0

			for i = MAX_ROWS + 1, #s.groups do
				rest = rest + s.groups[i].bytes
			end

			rows[#rows + 1] = {
				label = string.format("%d more labels", #s.groups - MAX_ROWS),
				value = format_bytes(rest),
				color = "dim",
			}
		end

		if s.pending_groups[1] then
			rows[#rows + 1] = {label = "awaiting release", color = "dim"}

			for i = 1, math.min(5, #s.pending_groups) do
				rows[#rows + 1] = {
					label = s.pending_groups[i].label,
					value = format_bytes(s.pending_groups[i].bytes),
					color = "dim",
				}
			end
		end

	return rows
	end

	perf.RegisterTab(
		"MEMORY",
		2,
		react.Component(|| -> ui.StatTable{
			Size = Vec2(660, 430),
			Rows = react.UsePoll(|| -> build_rows(take_snapshot()), WINDOW),
		})
	)

	commands.Add("vram_dump=number[40]", function(limit)
		local s = take_snapshot()
		logn(
			string.format(
				"VRAM: %s of %s device local, %d allocations, %d labels, %s awaiting release",
				format_bytes(s.total),
				format_bytes(s.heap),
				s.count,
				#s.groups,
				format_bytes(s.pending)
			)
		)

		for i = 1, math.min(10, #s.pending_groups) do
			logn(
				string.format(
					"awaiting release: %10s  %s",
					format_bytes(s.pending_groups[i].bytes),
					s.pending_groups[i].label
				)
			)
		end

		for i = 1, math.min(limit, #s.groups) do
			local group = s.groups[i]
			logn(
				string.format(
					"%10s  %5.1f%%  x%-5d %s",
					format_bytes(group.bytes),
					group.bytes / s.total * 100,
					group.count,
					group.label
				)
			)
		end
	end)
end

do
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
end
