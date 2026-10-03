local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local index_pool = {}
local UInt32Array = ffi.typeof("uint32_t *")
local MIN_CAPACITY = 2 ^ 20
local MIN_RANGE = 64
local REUSE_DELAY = 16
local buffer
local pointer
local shadow
local capacity = 0
local top = 0
local entries = setmetatable({}, {__mode = "k"})
local free_ranges = {}
local pending_frees = {}
local retired = {}

local function get_range_size(count)
	if count <= MIN_RANGE then return MIN_RANGE end

	local power = 2 ^ math.floor(math.log(count, 2))
	local step = power / 8
	return math.ceil(count / step) * step
end

local function collect_delayed()
	local frame = system.GetFrameNumber()

	while pending_frees[1] and frame - pending_frees[1].frame >= REUSE_DELAY do
		local range = table.remove(pending_frees, 1)
		local list = free_ranges[range.size]

		if not list then
			list = {}
			free_ranges[range.size] = list
		end

		list[#list + 1] = range.first
	end

	while retired[1] and frame - retired[1].frame >= REUSE_DELAY do
		table.remove(retired, 1).buffer:Remove()
	end
end

local function grow(needed)
	local new_capacity = math.max(needed, math.ceil(capacity * 1.5), MIN_CAPACITY)
	local new_buffer = render.CreateBuffer{
		byte_size = new_capacity * 4,
		buffer_usage = {"index_buffer"},
		memory_property = {"host_visible", "host_coherent"},
		label = "index_pool",
	}
	local new_pointer = ffi.cast(UInt32Array, new_buffer:Map())
	local new_shadow = ffi.new("uint32_t[?]", new_capacity)

	if buffer then
		ffi.copy(new_shadow, shadow, top * 4)
		ffi.copy(new_pointer, new_shadow, top * 4)
		retired[#retired + 1] = {buffer = buffer, frame = system.GetFrameNumber()}
	end

	buffer = new_buffer
	pointer = new_pointer
	shadow = new_shadow
	capacity = new_capacity
end

local function alloc(size)
	local list = free_ranges[size]

	if list and #list > 0 then return table.remove(list) end

	if top + size > capacity then grow(top + size) end

	local first = top
	top = top + size
	return first
end

function index_pool.GetFirstIndex(index_buffer)
	local entry = entries[index_buffer]

	if entry then return entry.first end

	collect_delayed()
	local count = index_buffer:GetIndexCount()
	local size = get_range_size(count)
	local first = alloc(size)
	local data = index_buffer:GetData()
	local destination = shadow + first

	if type(data) == "cdata" then
		local typed = ffi.cast(index_buffer:GetIndexTypeFFI() .. "*", data)

		for i = 0, count - 1 do
			destination[i] = typed[i]
		end
	else
		for i = 0, count - 1 do
			destination[i] = data[i + 1]
		end
	end

	ffi.copy(pointer + first, destination, count * 4)
	entry = {
		first = first,
		guard = ffi.gc(ffi.new("char[1]"), function()
			pending_frees[#pending_frees + 1] = {first = first, size = size, frame = system.GetFrameNumber()}
		end),
	}
	entries[index_buffer] = entry
	return first
end

function index_pool.GetBuffer()
	if not buffer then grow(MIN_CAPACITY) end

	return buffer
end

return index_pool
