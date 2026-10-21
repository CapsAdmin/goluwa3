local Memory = import("goluwa/render/vulkan/internal/memory.lua")
local buffer_pool = {}
local BLOCK_SIZE = 64 * 2 ^ 20
local ALIGNMENT = 256
buffer_pool.MAX_BUFFER_SIZE = 4 * 2 ^ 20

local function get_class_size(size)
	if size <= ALIGNMENT then return ALIGNMENT end

	local step = math.max(2 ^ math.floor(math.log(size, 2)) / 8, ALIGNMENT)
	return math.ceil(size / step) * step
end

function buffer_pool.Allocate(device, type_index, flags, size, alignment)
	size = tonumber(size)
	alignment = tonumber(alignment)

	if size > buffer_pool.MAX_BUFFER_SIZE or alignment > ALIGNMENT then
		return nil
	end

	size = get_class_size(size)
	local pools = device.buffer_pools

	if not pools then
		pools = {}
		device.buffer_pools = pools
	end

	local key = type_index .. ":" .. (flags and table.concat(flags, ",") or "")
	local pool = pools[key]

	if not pool or (pool.current and not pool.current.memory:IsValid()) then
		pool = {free = {}, blocks = {}}
		pools[key] = pool
	end

	local free = pool.free[size]
	local allocation = free and table.remove(free)

	if allocation then return allocation end

	local block = pool.current

	if not block or block.top + size > BLOCK_SIZE then
		block = {
			memory = Memory.New(
				device,
				{
					size = BLOCK_SIZE,
					type_index = type_index,
					flags = flags,
					label = "small buffers",
				}
			),
			top = 0,
		}
		pool.blocks[#pool.blocks + 1] = block
		block.memory:SetDebugName("small buffers memory")
		pool.current = block
	end

	allocation = {block = block, offset = block.top, size = size, free = pool.free[size]}

	if not allocation.free then
		allocation.free = {}
		pool.free[size] = allocation.free
	end

	block.top = block.top + size
	return allocation
end

function buffer_pool.Free(allocation)
	local free = allocation.free
	free[#free + 1] = allocation
end

return buffer_pool
