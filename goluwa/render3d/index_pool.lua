local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local index_pool = {}
-- One uint32 index buffer that the indices of every mesh drawn by the
-- multi-draws are copied into, so a draw is a firstIndex into it instead of a
-- buffer of its own. Indices stay mesh local: the vertices are pulled through
-- the mesh's buffer address, so vertexOffset is 0. Hardware indexed draws
-- shade each vertex once per draw, not once per triangle corner.
local UInt32Array = ffi.typeof("uint32_t *")
local MIN_CAPACITY = 2 ^ 20
local MIN_RANGE = 64
-- a freed range or a replaced buffer may still be read by frames in flight
local REUSE_DELAY = 16
local buffer
local pointer
local capacity = 0
local top = 0
local entries = setmetatable({}, {__mode = "k"})
local free_ranges = {}
local pending_frees = {}
local retired = {}

-- 1/8 steps of a power of two, so reusing a range wastes at most an eighth
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

	if buffer then
		ffi.copy(new_pointer, pointer, top * 4)
		retired[#retired + 1] = {buffer = buffer, frame = system.GetFrameNumber()}
	end

	buffer = new_buffer
	pointer = new_pointer
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

-- the index in the pool of the first index of index_buffer's indices, copying
-- them in the first time. call it before GetBuffer, the buffer can be replaced
function index_pool.GetFirstIndex(index_buffer)
	local entry = entries[index_buffer]

	if entry then return entry.first end

	collect_delayed()
	local count = index_buffer:GetIndexCount()
	local size = get_range_size(count)
	local first = alloc(size)
	local data = index_buffer:GetData()
	local destination = pointer + first

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

	-- the range goes back once the index buffer is collected and its entry with it
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
