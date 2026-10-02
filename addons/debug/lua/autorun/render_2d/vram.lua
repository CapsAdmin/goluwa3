if not RENDER_2D then return end

local Color = import("goluwa/structs/color.lua")
local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local vulkan_memory = import("goluwa/render/vulkan/internal/memory.lua")
-- VRAM overlay. F2 toggles it (or the vram command). Allocations are grouped
-- by the label the object was created with, so a buffer made with
-- label = "scene_bvh_triangles" shows up as that. Numbers are the sizes of the
-- live device memory allocations, which is what counts against the heap.
local WINDOW = 0.5
local MAX_ROWS = 28
local LINE_HEIGHT = 15
local PANEL_WIDTH = 520
local SIZE_X = 330
local COUNT_X = 410
local BAR_X = 440
local BAR_WIDTH = 70
local WHITE = Color(0.88, 0.9, 0.94, 1)
local DIM = Color(0.6, 0.64, 0.7, 1)
local HEAD = Color(1, 0.85, 0.4, 1)
local WARN = Color(1, 0.5, 0.4, 1)
local visible = false
local window_start = 0
local snapshot
local row_y = 0
local panel_height = 480

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

local function take_snapshot()
	local groups = {}
	local total = 0
	local count = 0

	for _, memory in pairs(vulkan_memory.Instances) do
		if memory:IsValid() then
			local label = memory.debug_name and memory.debug_name:gsub(" memory$", "") or "(unnamed)"
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
	return {groups = sorted, total = total, count = count, heap = get_device_heap_bytes()}
end

local function text(x, panel_x, label, color)
	render2d.DrawText{
		text = label,
		x = panel_x + x,
		y = row_y,
		foreground_color = color or WHITE,
	}
end

local function draw_snapshot(x, y)
	local s = snapshot
	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.72)
	render2d.DrawRoundedRect(x, y, PANEL_WIDTH, panel_height, 6)
	row_y = y + 8
	local fraction = s.heap > 0 and s.total / s.heap or 0
	text(
		10,
		x,
		string.format(
			"vram  %s of %s device local (%.0f%%)  %d allocations",
			format_bytes(s.total),
			format_bytes(s.heap),
			fraction * 100,
			s.count
		),
		fraction > 0.9 and WARN or HEAD
	)
	row_y = row_y + LINE_HEIGHT + 4

	for i = 1, math.min(MAX_ROWS, #s.groups) do
		local group = s.groups[i]
		local share = group.bytes / s.total
		text(10, x, group.label, i == 1 and HEAD or WHITE)
		text(SIZE_X, x, format_bytes(group.bytes), WHITE)
		text(COUNT_X, x, "x" .. group.count, DIM)
		render2d.SetTexture(nil)
		render2d.SetColor(0.35, 0.6, 0.95, 0.85)
		render2d.DrawRect(x + BAR_X, row_y + 3, BAR_WIDTH * share, LINE_HEIGHT - 8)
		row_y = row_y + LINE_HEIGHT
	end

	if #s.groups > MAX_ROWS then
		local rest = 0

		for i = MAX_ROWS + 1, #s.groups do
			rest = rest + s.groups[i].bytes
		end

		text(10, x, string.format("%d more labels", #s.groups - MAX_ROWS), DIM)
		text(SIZE_X, x, format_bytes(rest), DIM)
		row_y = row_y + LINE_HEIGHT
	end

	panel_height = row_y - y + 10
end

event.AddListener("Draw2D", "vram_hud", function()
	if not visible then return end

	local now = system.GetElapsedTime()

	if not snapshot or now - window_start >= WINDOW then
		snapshot = take_snapshot()
		window_start = now
	end

	draw_snapshot(10, 10)
end)

event.AddListener("KeyInput", "vram_hud_toggle", function(key, press)
	if press and key == "f2" then visible = not visible end
end)

commands.Add("vram", function()
	visible = not visible
	print("[VRAM] " .. (visible and "Enabled" or "Disabled"))
end)

commands.Add("vram_dump=number[40]", function(limit)
	local s = take_snapshot()
	logn(
		string.format(
			"VRAM: %s of %s device local, %d allocations, %d labels",
			format_bytes(s.total),
			format_bytes(s.heap),
			s.count,
			#s.groups
		)
	)

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
