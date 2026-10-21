local ffi = require("ffi")
local system = import("goluwa/system.lua")
local stats = {}
local current = {}
local last_second = {}
local FRAMETIME_HISTORY_SIZE = 120
local frametime_history = ffi.new("float[?]", FRAMETIME_HISTORY_SIZE)
local frametime_history_count = 0
local frametime_history_head = 0
local registered_groups = {}
local registered_group_order = {}
local registered_fields = {}
local registered_field_order = {}
local public = {
	current = current,
	last_second = last_second,
	history = frametime_history,
	history_size = FRAMETIME_HISTORY_SIZE,
	history_count = 0,
	history_head = 0,
}
local window_start = 0
local started = false
local suppress_depth = 0

local function reset_bucket(bucket)
	bucket.seconds = 0
	bucket.frames = 0
	bucket.fps = 0
	bucket.frametime_sum = 0
	bucket.frametime_avg = 0
	bucket.frametime_min = 0
	bucket.frametime_max = 0
	bucket.pipeline_switches = 0
	bucket.bytes_uploaded = 0
	bucket.upload_calls = 0
	bucket.draw_calls = 0
	bucket.descriptor_writes = 0
	bucket.descriptor_update_calls = 0
end

reset_bucket(current)
reset_bucket(last_second)

local function ensure_started(now)
	if started then return end

	started = true
	window_start = now or system.GetElapsedTime()
	reset_bucket(current)
	reset_bucket(last_second)
end

local function should_ignore_counters()
	return suppress_depth > 0
end

local function record_frametime_history(dt)
	frametime_history[frametime_history_head] = dt
	frametime_history_head = (frametime_history_head + 1) % FRAMETIME_HISTORY_SIZE

	if frametime_history_count < FRAMETIME_HISTORY_SIZE then
		frametime_history_count = frametime_history_count + 1
	end

	public.history_count = frametime_history_count
	public.history_head = frametime_history_head
end

local function publish_window(now)
	local elapsed = now - window_start

	if elapsed <= 0 then return end

	last_second.seconds = elapsed
	last_second.frames = current.frames
	last_second.fps = current.frames / elapsed
	last_second.frametime_sum = current.frametime_sum
	last_second.frametime_avg = current.frames > 0 and current.frametime_sum / current.frames or 0
	last_second.frametime_min = current.frames > 0 and current.frametime_min or 0
	last_second.frametime_max = current.frametime_max
	last_second.pipeline_switches = current.pipeline_switches
	last_second.bytes_uploaded = current.bytes_uploaded
	last_second.upload_calls = current.upload_calls
	last_second.draw_calls = current.draw_calls
	last_second.descriptor_writes = current.descriptor_writes
	last_second.descriptor_update_calls = current.descriptor_update_calls
	reset_bucket(current)
	window_start = now
end

local function get_display_bucket()
	if last_second.frames > 0 then return last_second end

	return current
end

local function round_positive(value)
	return math.floor((value or 0) + 0.5)
end

local function format_bytes(value)
	value = tonumber(value) or 0
	local unit_index = 1
	local units = {"B", "KB", "MB", "GB"}

	while value >= 1024 and unit_index < #units do
		value = math.floor((value + 512) / 1024)
		unit_index = unit_index + 1
	end

	return tostring(value) .. " " .. units[unit_index]
end

local function format_integer(value)
	return tostring(round_positive(value))
end

local function format_frametime_ms(value)
	return tostring(round_positive((tonumber(value) or 0) * 1000)) .. " MS"
end

local function build_field_text(field, bucket)
	local value

	if field.getter then
		value = field.getter(bucket, public, field)
	elseif field.bucket_key then
		value = bucket[field.bucket_key]
	else
		value = field.value
	end

	if value == nil and field.default ~= nil then value = field.default end

	local text

	if field.formatter then
		text = field.formatter(value, bucket, public, field)
	elseif type(value) == "boolean" then
		text = value and "ON" or "OFF"
	elseif type(value) == "number" then
		text = format_integer(value)
	elseif value == nil then
		text = "-"
	else
		text = tostring(value)
	end

	return tostring(text or "")
end

function stats.RecordFrame(dt)
	local now = system.GetElapsedTime()
	ensure_started(now)
	record_frametime_history(dt)
	current.frames = current.frames + 1
	current.frametime_sum = current.frametime_sum + dt

	if current.frames == 1 or dt < current.frametime_min then
		current.frametime_min = dt
	end

	if dt > current.frametime_max then current.frametime_max = dt end

	current.seconds = now - window_start
	current.fps = current.seconds > 0 and current.frames / current.seconds or 0
	current.frametime_avg = current.frametime_sum / current.frames

	if current.seconds >= 1 then publish_window(now) end
end

function stats.PushIgnore()
	suppress_depth = suppress_depth + 1
end

function stats.PopIgnore()
	if suppress_depth > 0 then suppress_depth = suppress_depth - 1 end
end

function stats.AddPipelineSwitches(count)
	if should_ignore_counters() then return end

	ensure_started()
	current.pipeline_switches = current.pipeline_switches + (count or 1)
end

function stats.AddUploadedBytes(byte_count)
	if should_ignore_counters() then return end

	ensure_started()
	current.bytes_uploaded = current.bytes_uploaded + (byte_count or 0)
	current.upload_calls = current.upload_calls + 1
end

function stats.AddDrawCalls(count)
	if should_ignore_counters() then return end

	ensure_started()
	current.draw_calls = current.draw_calls + (count or 1)
end

function stats.AddDescriptorWrites(write_count)
	if should_ignore_counters() then return end

	ensure_started()
	current.descriptor_writes = current.descriptor_writes + (write_count or 1)
	current.descriptor_update_calls = current.descriptor_update_calls + 1
end

function stats.Reset()
	started = false
	window_start = 0
	suppress_depth = 0
	frametime_history_count = 0
	frametime_history_head = 0
	public.history_count = 0
	public.history_head = 0
	reset_bucket(current)
	reset_bucket(last_second)
end

function stats.RegisterGroup(id, group)
	if type(id) == "table" then
		group = id
		id = group and group.id
	end

	if not id then error("render.stats group id is required", 2) end

	group = group or {}
	group.id = id
	group.label = group.label or tostring(id):upper()
	registered_groups[id] = group
	local found = false

	for i = 1, #registered_group_order do
		if registered_group_order[i] == id then
			found = true

			break
		end
	end

	if not found then registered_group_order[#registered_group_order + 1] = id end

	return group
end

function stats.UnregisterGroup(id)
	if not registered_groups[id] then return end

	registered_groups[id] = nil

	for i = 1, #registered_group_order do
		if registered_group_order[i] == id then
			table.remove(registered_group_order, i)

			break
		end
	end

end

function stats.RegisterField(id, field)
	if type(id) == "table" then
		field = id
		id = field and field.id
	end

	if not id then error("render.stats field id is required", 2) end

	field = field or {}
	field.id = id
	field.label = field.label or tostring(id):upper()
	registered_fields[id] = field
	local found = false

	for i = 1, #registered_field_order do
		if registered_field_order[i] == id then
			found = true

			break
		end
	end

	if not found then registered_field_order[#registered_field_order + 1] = id end

	return field
end

function stats.UnregisterField(id)
	if not registered_fields[id] then return end

	registered_fields[id] = nil

	for i = 1, #registered_field_order do
		if registered_field_order[i] == id then
			table.remove(registered_field_order, i)

			break
		end
	end

end

function stats.FormatBytes(value)
	return format_bytes(value)
end

function stats.Get()
	return public
end

function stats.GetRows()
	local bucket = get_display_bucket()
	local rows = {}

	local function add_field(id)
		local field = registered_fields[id]
		local label = field.label_getter and field.label_getter(field) or field.label
		rows[#rows + 1] = {group = field.group, label = label:lower(), value = build_field_text(field, bucket)}
	end

	for _, id in ipairs(registered_field_order) do
		if not registered_fields[id].group then add_field(id) end
	end

	for _, group_id in ipairs(registered_group_order) do
		local group = registered_groups[group_id]
		rows[#rows + 1] = {group = group_id, label = group.label:lower(), color = "head"}

		for _, id in ipairs(registered_field_order) do
			if registered_fields[id].group == group_id then add_field(id) end
		end
	end

	return rows
end

stats.RegisterGroup{
	id = "render",
	label = "RENDER",
}
stats.RegisterField{
	id = "fps",
	label = "FPS",
	bucket_key = "fps",
	formatter = format_integer,
	group = "render",
}
stats.RegisterField{
	id = "frame_ms",
	label = "FRAME",
	bucket_key = "frametime_avg",
	formatter = format_frametime_ms,
	group = "render",
}
stats.RegisterField{
	id = "pipeline_switches",
	label = "PIPELINES",
	bucket_key = "pipeline_switches",
	formatter = format_integer,
	group = "render",
}
stats.RegisterField{
	id = "bytes_uploaded",
	label = "UPLOAD",
	bucket_key = "bytes_uploaded",
	formatter = format_bytes,
	group = "render",
}
stats.RegisterField{
	id = "upload_calls",
	label = "UPLOAD CALLS",
	bucket_key = "upload_calls",
	formatter = format_integer,
	group = "render",
}
stats.RegisterField{
	id = "draw_calls",
	label = "DRAWS",
	bucket_key = "draw_calls",
	formatter = format_integer,
	group = "render",
}
stats.RegisterField{
	id = "descriptor_writes",
	label = "DESC WRITES",
	bucket_key = "descriptor_writes",
	formatter = format_integer,
	group = "render",
}
stats.RegisterField{
	id = "descriptor_update_calls",
	label = "DESC UPDATES",
	bucket_key = "descriptor_update_calls",
	formatter = format_integer,
	group = "render",
}
return stats
