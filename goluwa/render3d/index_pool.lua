local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local memory = import("goluwa/bindings/memory.lua")
local OffsetAllocator = import("goluwa/render3d/offset_allocator.lua")
local index_pool = {}
local UInt32 = ffi.typeof("uint32_t")
local UInt32Array = ffi.typeof("uint32_t *")
local MIN_CAPACITY = 2 ^ 20
local MIN_RANGE = 3
local REUSE_DELAY = 16
local buffer
local pointer
local shadow
local capacity = 0
local pool
local entries = setmetatable({}, {__mode = "k"})
local pending_frees = {}
local retired = {}

local function collect_delayed()
	local frame = system.GetFrameNumber()

	while pending_frees[1] and frame - pending_frees[1].frame >= REUSE_DELAY do
		pool:Free(table.remove(pending_frees, 1).node)
	end

	while retired[1] and frame - retired[1].frame >= REUSE_DELAY do
		table.remove(retired, 1).buffer:Remove()
	end
end

local function grow(extra)
	local new_capacity = math.max(capacity + extra, MIN_CAPACITY)
	local new_buffer = render.CreateBuffer{
		byte_size = new_capacity * 4,
		buffer_usage = {"index_buffer"},
		memory_property = {"host_visible", "host_coherent"},
		label = "index_pool",
	}
	local new_pointer = ffi.cast(UInt32Array, new_buffer:Map())
	local new_shadow = memory.NewArray(UInt32, new_capacity)

	if buffer then
		ffi.copy(new_shadow, shadow, capacity * 4)
		ffi.copy(new_pointer, new_shadow, capacity * 4)
		retired[#retired + 1] = {buffer = buffer, frame = system.GetFrameNumber()}
		pool:Grow(new_capacity - capacity)
	else
		pool = OffsetAllocator.New(new_capacity)
	end

	buffer = new_buffer
	pointer = new_pointer
	shadow = new_shadow
	capacity = new_capacity
end

local function alloc(size)
	if not pool then grow(0) end

	local offset, node = pool:Alloc(size)

	while not offset do
		grow(math.max(math.ceil(size * 1.25), math.ceil(capacity * 0.5)))
		offset, node = pool:Alloc(size)
	end

	return offset, node
end

function index_pool.GetFirstIndex(index_buffer)
	local entry = entries[index_buffer]

	if entry then return entry.first end

	collect_delayed()
	local count = index_buffer:GetIndexCount()
	local first, node = alloc(math.max(count, MIN_RANGE))
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
			pending_frees[#pending_frees + 1] = {node = node, frame = system.GetFrameNumber()}
		end),
	}
	entries[index_buffer] = entry
	return first
end

function index_pool.AllocateRange(owner, source, count)
	collect_delayed()
	local first, node = alloc(math.max(count, MIN_RANGE))
	ffi.copy(shadow + first, source, count * 4)
	ffi.copy(pointer + first, source, count * 4)
	entries[owner] = {
		first = first,
		guard = ffi.gc(ffi.new("char[1]"), function()
			pending_frees[#pending_frees + 1] = {node = node, frame = system.GetFrameNumber()}
		end),
	}
	return first
end

function index_pool.GetBuffer()
	if not buffer then grow(0) end

	return buffer
end

return index_pool
