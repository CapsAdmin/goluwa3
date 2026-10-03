local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local QueryPool = import("goluwa/render/vulkan/internal/query_pool.lua")
local render_stats = import("goluwa/render/stats.lua")
local gpu_timing = {}
local serialized = os.getenv("GOLUWA_GPU_SERIALIZE") == "1"
local MAX_SCOPES = 128
local STALE_SECONDS = 1
local RESULT_FLAGS = bit.bor(
	vulkan.vk.VkQueryResultFlagBits.VK_QUERY_RESULT_64_BIT,
	vulkan.vk.VkQueryResultFlagBits.VK_QUERY_RESULT_WITH_AVAILABILITY_BIT
)
local slot_by_name = {}
local slot_order = {}
local display_order = {}
local display_labels = {}
local sequence = {}
local sequence_seen = {}
local sequence_frame
local positions = {}
local pools = {}
local last_ms = {}
local smoothed_ms = {}
local timestamp_period_ns
local timestamps_supported

local function timestamps_are_supported()
	if timestamps_supported ~= nil then return timestamps_supported end

	local queue_family_index = render.GetGraphicsQueueFamilyIndex()
	local families = render.GetPhysicalDevice():GetQueueFamilyProperties()
	local family = families[queue_family_index + 1]
	timestamps_supported = family ~= nil and tonumber(family.timestampValidBits) > 0

	if not timestamps_supported then
		logf(
			"[gpu_timing] graphics queue family reports timestampValidBits == 0; GPU pass timing disabled\n"
		)
	end

	return timestamps_supported
end

render_stats.RegisterGroup{id = "gpu_timing", label = "GPU TIMINGS IN MICROSECONDS", columns = true}
local TOTAL_NAME = "gpu_total"
local get_total_ms

local function get_everything_ms()
	local total

	for i = 1, #slot_order do
		local name = slot_order[i]

		if name == "gpu_frame" or name:find("^shadow_") then
			local ms = get_total_ms(name)

			if ms then total = (total or 0) + ms end
		end
	end

	return total
end

function get_total_ms(name)
	if name == TOTAL_NAME then return get_everything_ms() end

	local now = system.GetElapsedTime()
	local total

	for _, pool in pairs(pools) do
		local time = pool.gpu_timing_times[name]

		if time and now - time <= STALE_SECONDS then
			total = (total or 0) + pool.gpu_timing_ms[name]
		end
	end

	return total
end

local shown_ms = {}
local shown_frame
local shown_min
local shown_max

local function update_shown()
	local frame = system.GetFrameNumber()

	if shown_frame == frame then return end

	shown_frame = frame
	shown_min = nil
	shown_max = nil

	for i = 1, #display_order do
		local name = display_order[i]
		local total = get_total_ms(name)

		if total then
			local smoothed = smoothed_ms[name] and (smoothed_ms[name] * 0.85 + total * 0.15) or total
			smoothed_ms[name] = smoothed
			shown_ms[name] = smoothed

			if name ~= "gpu_frame" and name ~= TOTAL_NAME then
				shown_min = shown_min and math.min(shown_min, smoothed) or smoothed
				shown_max = shown_max and math.max(shown_max, smoothed) or smoothed
			end
		else
			smoothed_ms[name] = nil
			shown_ms[name] = nil
		end
	end
end

local function register_row(rank)
	render_stats.RegisterField{
		id = "gpu_timing_row_" .. rank,
		group = "gpu_timing",
		glyphs = "-",
		label_getter = function()
			return display_labels[display_order[rank]]
		end,
		getter = function()
			update_shown()
			local ms = shown_ms[display_order[rank]]
			return ms and tostring(math.floor(ms * 1000 + 0.5)) or "-"
		end,
		swatch_getter = function()
			update_shown()
			local name = display_order[rank]
			local ms = shown_ms[name]

			if not ms or name == "gpu_frame" or name == TOTAL_NAME then return nil end

			local t = shown_max > shown_min and (ms - shown_min) / (shown_max - shown_min) or 0

			if t < 0.5 then return t * 2, 1, 0 end

			return 1, (1 - t) * 2, 0
		end,
	}
end

local function get_slot(name)
	local slot = slot_by_name[name]

	if slot then return slot end

	slot = #slot_order

	if slot >= MAX_SCOPES then
		error("gpu_timing: too many scopes registered (max " .. MAX_SCOPES .. ")", 3)
	end

	slot_by_name[name] = slot
	slot_order[slot + 1] = name
	display_labels[name] = name:gsub("^gpu_", ""):gsub("_", " "):upper()
	display_order[#display_order + 1] = name
	register_row(#display_order)
	return slot
end

local function apply_sequence()
	local count = 0

	for i = 1, #display_order do
		if sequence_seen[display_order[i]] then
			count = count + 1
			positions[count] = i
		end
	end

	for i = 1, count do
		display_order[positions[i]] = sequence[i]
	end

	for i = 1, #sequence do
		sequence_seen[sequence[i]] = nil
		sequence[i] = nil
	end
end

local function note_begun(name)
	local frame = system.GetFrameNumber()

	if sequence_frame ~= frame then
		apply_sequence()
		sequence_frame = frame
	end

	if not sequence_seen[name] then
		sequence_seen[name] = true
		sequence[#sequence + 1] = name
	end
end

local function get_pool(cmd)
	local pool = pools[cmd]

	if pool then return pool end

	pool = QueryPool.New(render.GetDevice(), "timestamp", MAX_SCOPES * 2)
	pool.gpu_timing_ms = {}
	pool.gpu_timing_times = {}
	pool.gpu_timing_used = {}
	pool.gpu_timing_skipped = {}
	pools[cmd] = pool
	return pool
end

local function get_timestamp_period()
	if not timestamp_period_ns then
		timestamp_period_ns = render.GetPhysicalDevice():GetProperties().limits.timestampPeriod
	end

	return timestamp_period_ns
end

local function read_back_pool(pool)
	local scope_count = #slot_order

	if scope_count == 0 then return end

	local query_count = scope_count * 2
	local data = ffi.new("uint64_t[?]", query_count * 2)
	vulkan.lib.vkGetQueryPoolResults(
		pool.device.ptr[0],
		pool.ptr[0],
		0,
		query_count,
		ffi.sizeof("uint64_t") * query_count * 2,
		data,
		ffi.sizeof("uint64_t") * 2,
		RESULT_FLAGS
	)
	local period = get_timestamp_period()
	local now = system.GetElapsedTime()

	for slot = 0, scope_count - 1 do
		local begin_value = data[slot * 4 + 0]
		local begin_available = data[slot * 4 + 1]
		local end_value = data[slot * 4 + 2]
		local end_available = data[slot * 4 + 3]

		if begin_available ~= 0 and end_available ~= 0 and end_value > begin_value then
			local name = slot_order[slot + 1]
			local ms = tonumber(end_value - begin_value) * period / 1e6
			pool.gpu_timing_ms[name] = ms
			pool.gpu_timing_times[name] = now
			last_ms[name] = ms
		end
	end
end

function gpu_timing.BeginCommandBuffer(cmd)
	if not render.available or not timestamps_are_supported() then return end

	local pool = get_pool(cmd)

	if pool.gpu_timing_recorded then read_back_pool(pool) end

	pool:Reset(cmd, 0, MAX_SCOPES * 2)
	pool.gpu_timing_recorded = true
	pool.gpu_timing_used = {}
	pool.gpu_timing_skipped = {}
end

function gpu_timing.BeginFrame(cmd)
	gpu_timing.BeginCommandBuffer(cmd)
	gpu_timing.BeginScope(cmd, "gpu_frame")
end

function gpu_timing.BeginScope(cmd, name)
	if not render.available or not timestamps_are_supported() then return end

	local slot = get_slot(name)
	note_begun(name)
	local pool = get_pool(cmd)

	if pool.gpu_timing_used[slot] then
		pool.gpu_timing_skipped[slot] = (pool.gpu_timing_skipped[slot] or 0) + 1
		return
	end

	pool.gpu_timing_used[slot] = true

	if serialized then
		cmd:PipelineBarrier{srcStage = "all_commands", dstStage = "all_commands", memoryBarrier = true}
	end

	pool:WriteTimestamp(cmd, slot * 2, "top_of_pipe")
end

function gpu_timing.EndScope(cmd, name)
	if not render.available or not timestamps_are_supported() then return end

	local slot = slot_by_name[name]

	if not slot then return end

	local pool = get_pool(cmd)
	local skipped = pool.gpu_timing_skipped[slot] or 0

	if skipped > 0 then
		pool.gpu_timing_skipped[slot] = skipped - 1
		return
	end

	pool:WriteTimestamp(cmd, slot * 2 + 1, "bottom_of_pipe")

	if serialized then
		cmd:PipelineBarrier{srcStage = "all_commands", dstStage = "all_commands", memoryBarrier = true}
	end
end

function gpu_timing.GetMilliseconds(name)
	return get_total_ms(name) or 0
end

function gpu_timing.GetRawMilliseconds(name)
	return last_ms[name] or 0
end

function gpu_timing.GetScopeNames()
	return slot_order
end

function gpu_timing.SetSerialized(value)
	serialized = value
end

function gpu_timing.IsSerialized()
	return serialized
end

get_slot(TOTAL_NAME)
return gpu_timing
