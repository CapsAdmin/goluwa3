local ffi = require("ffi")
local system = import("goluwa/system.lua")
local commands = import("goluwa/commands.lua")
local probe = {}
local STRONG_KEY = {}
probe.enabled = false
probe.started_at = 0
probe.last_reset_at = 0
probe.block_stats = {}
probe.snapshots = {}
probe.cache_keys = {}

local function is_weak_key(value)
	local t = type(value)
	return t == "table" or t == "userdata"
end

local function get_snapshot_store(block_name)
	local store = probe.snapshots[block_name]

	if store then return store end

	store = {
		strong = {},
		weak = setmetatable({}, {__mode = "k"}),
	}
	probe.snapshots[block_name] = store
	return store
end

local function get_snapshot_entry(block_name, key)
	local store = get_snapshot_store(block_name)

	if key == nil then key = STRONG_KEY end

	if is_weak_key(key) then
		local snapshot = store.weak[key]

		if snapshot then return snapshot end

		snapshot = {}
		store.weak[key] = snapshot
		return snapshot
	end

	local snapshot = store.strong[key]

	if snapshot then return snapshot end

	snapshot = {}
	store.strong[key] = snapshot
	return snapshot
end

local function get_cache_key_store(block_name)
	local store = probe.cache_keys[block_name]

	if store then return store end

	store = {
		strong = {},
		weak = setmetatable({}, {__mode = "k"}),
	}
	probe.cache_keys[block_name] = store
	return store
end

local function note_unique_cache_key(block_stats, block_name, key)
	local store = get_cache_key_store(block_name)

	if key == nil then key = STRONG_KEY end

	if is_weak_key(key) then
		if store.weak[key] then return end

		store.weak[key] = true
		block_stats.unique_keys = block_stats.unique_keys + 1
		return
	end

	if store.strong[key] then return end

	store.strong[key] = true
	block_stats.unique_keys = block_stats.unique_keys + 1
end

local function bytes_equal(lhs, rhs, size)
	for i = 0, size - 1 do
		if lhs[i] ~= rhs[i] then return false end
	end

	return true
end

local function get_block_stats(block_name)
	local stats = probe.block_stats[block_name]

	if stats then return stats end

	stats = {
		uploads = 0,
		bytes = 0,
		changes = 0,
		cache_accesses = 0,
		cache_hits = 0,
		cache_misses = 0,
		unique_keys = 0,
		fields = {},
	}
	probe.block_stats[block_name] = stats
	return stats
end

local function get_field_stats(block_stats, field_name)
	local stats = block_stats.fields[field_name]

	if stats then return stats end

	stats = {
		writes = 0,
		changes = 0,
		bytes = 0,
	}
	block_stats.fields[field_name] = stats
	return stats
end

function probe.IsEnabled()
	return probe.enabled == true
end

function probe.Reset()
	probe.block_stats = {}
	probe.snapshots = {}
	probe.cache_keys = {}
	probe.last_reset_at = system.GetElapsedTime and system.GetElapsedTime() or 0

	if probe.started_at == 0 then probe.started_at = probe.last_reset_at end
end

function probe.Start(reset)
	probe.enabled = true
	probe.started_at = system.GetElapsedTime and system.GetElapsedTime() or 0

	if reset ~= false then probe.Reset() end

	return true
end

function probe.Stop()
	probe.enabled = false
	return true
end

function probe.RecordUpload(block_name, field_descriptors, data, block_size, key)
	if not probe.enabled then return end

	local block_stats = get_block_stats(block_name)
	local snapshot = get_snapshot_entry(block_name, key)
	local src = ffi.cast("uint8_t*", data)
	local block_changed = false
	block_stats.uploads = block_stats.uploads + 1
	block_stats.bytes = block_stats.bytes + (block_size or 0)

	for i = 1, #field_descriptors do
		local desc = field_descriptors[i]
		local field_stats = get_field_stats(block_stats, desc.name)
		field_stats.writes = field_stats.writes + 1
		field_stats.bytes = field_stats.bytes + desc.size
		local field_ptr = src + desc.offset
		local previous = snapshot[desc.name]

		if not previous then
			previous = ffi.new("uint8_t[?]", desc.size)
			snapshot[desc.name] = previous
			field_stats.changes = field_stats.changes + 1
			block_changed = true
		elseif not bytes_equal(previous, field_ptr, desc.size) then
			field_stats.changes = field_stats.changes + 1
			block_changed = true
		end

		ffi.copy(previous, field_ptr, desc.size)
	end

	if block_changed then block_stats.changes = block_stats.changes + 1 end
end

function probe.RecordCacheAccess(block_name, key, hit)
	if not probe.enabled then return end

	local block_stats = get_block_stats(block_name)
	block_stats.cache_accesses = block_stats.cache_accesses + 1

	if hit then
		block_stats.cache_hits = block_stats.cache_hits + 1
	else
		block_stats.cache_misses = block_stats.cache_misses + 1
	end

	note_unique_cache_key(block_stats, block_name, key)
end

function probe.RecordUniformUpload(block_name, field_descriptors, data, block_size, key)
	return probe.RecordUpload(block_name, field_descriptors, data, block_size, key)
end

local function get_elapsed_window()
	local elapsed = (system.GetElapsedTime and system.GetElapsedTime() or 0) - (probe.last_reset_at or 0)

	if elapsed <= 0 then elapsed = 1 end

	return elapsed
end

local function collect_field_rows()
	local elapsed = get_elapsed_window()
	local rows = {}

	for block_name, block_stats in pairs(probe.block_stats) do
		for field_name, field_stats in pairs(block_stats.fields) do
			rows[#rows + 1] = {
				block_name = block_name,
				field_name = field_name,
				changes_per_second = field_stats.changes / elapsed,
				writes_per_second = field_stats.writes / elapsed,
				change_ratio = field_stats.writes > 0 and field_stats.changes / field_stats.writes or 0,
				bytes_per_second = field_stats.bytes / elapsed,
			}
		end
	end

	table.sort(rows, function(a, b)
		if a.changes_per_second ~= b.changes_per_second then
			return a.changes_per_second > b.changes_per_second
		end

		if a.writes_per_second ~= b.writes_per_second then
			return a.writes_per_second > b.writes_per_second
		end

		if a.block_name ~= b.block_name then return a.block_name < b.block_name end

		return a.field_name < b.field_name
	end)

	return rows, elapsed
end

local function collect_block_rows()
	local elapsed = get_elapsed_window()
	local rows = {}

	for block_name, block_stats in pairs(probe.block_stats) do
		rows[#rows + 1] = {
			block_name = block_name,
			changes_per_second = block_stats.changes / elapsed,
			uploads_per_second = block_stats.uploads / elapsed,
			change_ratio = block_stats.uploads > 0 and block_stats.changes / block_stats.uploads or 0,
			bytes_per_second = block_stats.bytes / elapsed,
			cache_accesses_per_second = block_stats.cache_accesses / elapsed,
			cache_hit_ratio = block_stats.cache_accesses > 0 and
				block_stats.cache_hits / block_stats.cache_accesses or
				0,
			cache_miss_ratio = block_stats.cache_accesses > 0 and
				block_stats.cache_misses / block_stats.cache_accesses or
				0,
			unique_keys = block_stats.unique_keys,
		}
	end

	table.sort(rows, function(a, b)
		if a.changes_per_second ~= b.changes_per_second then
			return a.changes_per_second > b.changes_per_second
		end

		if a.uploads_per_second ~= b.uploads_per_second then
			return a.uploads_per_second > b.uploads_per_second
		end

		return a.block_name < b.block_name
	end)

	return rows, elapsed
end

function probe.Dump(limit)
	limit = math.max(tonumber(limit) or 32, 1)
	local rows, elapsed = collect_field_rows()
	logf(
		"[upload_probe] elapsed=%.3fs enabled=%s rows=%d\n",
		elapsed,
		tostring(probe.enabled),
		#rows
	)

	for i = 1, math.min(limit, #rows) do
		local row = rows[i]
		logf(
			"[upload_probe] %s.%s changes/s=%.2f writes/s=%.2f change_ratio=%.3f bytes/s=%.1f\n",
			row.block_name,
			row.field_name,
			row.changes_per_second,
			row.writes_per_second,
			row.change_ratio,
			row.bytes_per_second
		)
	end

	return rows
end

function probe.DumpBlocks(limit)
	limit = math.max(tonumber(limit) or 32, 1)
	local rows, elapsed = collect_block_rows()
	logf(
		"[upload_probe_blocks] elapsed=%.3fs enabled=%s rows=%d\n",
		elapsed,
		tostring(probe.enabled),
		#rows
	)

	for i = 1, math.min(limit, #rows) do
		local row = rows[i]
		logf(
			"[upload_probe_blocks] %s changes/s=%.2f uploads/s=%.2f change_ratio=%.3f bytes/s=%.1f cache_accesses/s=%.2f hit_ratio=%.3f miss_ratio=%.3f unique_keys=%d\n",
			row.block_name,
			row.changes_per_second,
			row.uploads_per_second,
			row.change_ratio,
			row.bytes_per_second,
			row.cache_accesses_per_second,
			row.cache_hit_ratio,
			row.cache_miss_ratio,
			row.unique_keys
		)
	end

	return rows
end

commands.Add("upload_probe_start", function()
	probe.Start(true)
	logf("[upload_probe] started\n")
end)

commands.Add("upload_probe_stop", function()
	probe.Stop()
	logf("[upload_probe] stopped\n")
end)

commands.Add("upload_probe_reset", function()
	probe.Reset()
	logf("[upload_probe] reset\n")
end)

commands.Add("upload_probe_dump=number[32]", function(limit)
	probe.Dump(limit)
end)

commands.Add("upload_probe_dump_blocks=number[32]", function(limit)
	probe.DumpBlocks(limit)
end)

return probe
