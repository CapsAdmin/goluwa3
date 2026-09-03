local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local QueryPool = import("goluwa/render/vulkan/internal/query_pool.lua")
local render_stats = import("goluwa/render/stats.lua")
local gpu_timing = {}
-- All render passes for a frame are recorded into a single command buffer
-- that is submitted once with no CPU/GPU sync between passes, so wall-clock
-- timing around a pass's Draw() call only measures CPU recording time. GPU
-- timestamp queries are the only way to know how long a pass actually took
-- on the GPU.
--
-- Query pools are keyed by command buffer identity rather than frame index:
-- multiple independent render targets (the swapchain target, offscreen
-- screenshot/capture targets) each number their own frames starting at 1,
-- so keying by frame index alone would let unrelated targets collide on the
-- same pool. Each render target's command buffers are long-lived and reused
-- every frame, so this stays a small, bounded set of pools.
local MAX_SCOPES = 64
local RESULT_FLAGS = bit.bor(
	vulkan.vk.VkQueryResultFlagBits.VK_QUERY_RESULT_64_BIT,
	vulkan.vk.VkQueryResultFlagBits.VK_QUERY_RESULT_WITH_AVAILABILITY_BIT
)
local slot_by_name = {}
local slot_order = {}
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

local function format_gpu_ms(value)
	return tostring(math.floor((value or 0) + 0.5)) .. " MS"
end

render_stats.RegisterGroup{id = "gpu_timing", label = "GPU TIMING"}

local function register_scope_field(name)
	render_stats.RegisterField{
		id = "gpu_timing_" .. name,
		label = "GPU " .. name,
		group = "gpu_timing",
		formatter = format_gpu_ms,
		getter = function()
			return smoothed_ms[name] or 0
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
	register_scope_field(name)
	return slot
end

local function get_pool(cmd)
	local pool = pools[cmd]

	if pool then return pool end

	pool = QueryPool.New(render.GetDevice(), "timestamp", MAX_SCOPES * 2)
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
		ffi.sizeof(data),
		data,
		ffi.sizeof("uint64_t") * 2,
		RESULT_FLAGS
	)
	local period = get_timestamp_period()

	for slot = 0, scope_count - 1 do
		local begin_value = data[slot * 4 + 0]
		local begin_available = data[slot * 4 + 1]
		local end_value = data[slot * 4 + 2]
		local end_available = data[slot * 4 + 3]

		if begin_available ~= 0 and end_available ~= 0 and end_value > begin_value then
			local name = slot_order[slot + 1]
			local ms = tonumber(end_value - begin_value) * period / 1e6
			last_ms[name] = ms
			smoothed_ms[name] = smoothed_ms[name] and (smoothed_ms[name] * 0.85 + ms * 0.15) or ms
		end
	end
end

-- Marks the start of a new recording cycle on this command buffer: reads
-- back whatever this pool captured last time it was recorded (its GPU work
-- is guaranteed complete, since the caller only re-records a command buffer
-- after waiting on the fence from its previous submission), resets it, and
-- opens the "gpu_frame" scope spanning the whole recording.
function gpu_timing.BeginFrame(cmd)
	if not render.available or not timestamps_are_supported() then return end

	local pool = get_pool(cmd)

	if pool.gpu_timing_recorded then read_back_pool(pool) end

	pool:Reset(cmd, 0, MAX_SCOPES * 2)
	pool.gpu_timing_recorded = true
	gpu_timing.BeginScope(cmd, "gpu_frame")
end

function gpu_timing.BeginScope(cmd, name)
	if not render.available or not timestamps_are_supported() then return end

	local slot = get_slot(name)
	get_pool(cmd):WriteTimestamp(cmd, slot * 2, "top_of_pipe")
end

function gpu_timing.EndScope(cmd, name)
	if not render.available or not timestamps_are_supported() then return end

	local slot = slot_by_name[name]

	if not slot then return end

	get_pool(cmd):WriteTimestamp(cmd, slot * 2 + 1, "bottom_of_pipe")
end

function gpu_timing.GetMilliseconds(name)
	return smoothed_ms[name] or 0
end

function gpu_timing.GetRawMilliseconds(name)
	return last_ms[name] or 0
end

return gpu_timing
