local ffi = require("ffi")
local bit = require("bit")
local band, bor, bnot, lshift, rshift = bit.band, bit.bor, bit.bnot, bit.lshift, bit.rshift
local OffsetAllocator = {}
OffsetAllocator.__index = OffsetAllocator
local UInt32Array = ffi.typeof("uint32_t[?]")
local UInt8Array = ffi.typeof("uint8_t[?]")
local MANTISSA_BITS = 3
local MANTISSA_VALUE = 8
local MANTISSA_MASK = 7
local NUM_TOP_BINS = 32
local NUM_LEAF_BINS = 256
local UNUSED = 0xFFFFFFFF
local MAX_SIZE = 2 ^ 31 - 1

local function highest_bit(v)
	local n = 0

	if v >= 0x10000 then
		v = rshift(v, 16)
		n = 16
	end

	if v >= 0x100 then
		v = rshift(v, 8)
		n = n + 8
	end

	if v >= 0x10 then
		v = rshift(v, 4)
		n = n + 4
	end

	if v >= 0x4 then
		v = rshift(v, 2)
		n = n + 2
	end

	if v >= 0x2 then n = n + 1 end

	return n
end

local function lowest_bit_from(mask, start)
	local above = band(mask, bnot(lshift(1, start) - 1))

	if above == 0 then return nil end

	return highest_bit(band(above, -above))
end

local function float_round_up(size)
	if size < MANTISSA_VALUE then return size end

	local start_bit = highest_bit(size) - MANTISSA_BITS
	local mantissa = band(rshift(size, start_bit), MANTISSA_MASK)

	if band(size, lshift(1, start_bit) - 1) ~= 0 then mantissa = mantissa + 1 end

	return lshift(start_bit + 1, MANTISSA_BITS) + mantissa
end

local function float_round_down(size)
	if size < MANTISSA_VALUE then return size end

	local start_bit = highest_bit(size) - MANTISSA_BITS
	return bor(
		lshift(start_bit + 1, MANTISSA_BITS),
		band(rshift(size, start_bit), MANTISSA_MASK)
	)
end

local function float_to_size(bin)
	local exponent = rshift(bin, MANTISSA_BITS)
	local mantissa = band(bin, MANTISSA_MASK)

	if exponent == 0 then return mantissa end

	return lshift(bor(mantissa, MANTISSA_VALUE), exponent - 1)
end

local function grow_nodes(self)
	local old = self.node_capacity
	local capacity = old * 2

	for _, name in ipairs{"offset", "size", "bin_prev", "bin_next", "near_prev", "near_next"} do
		local array = UInt32Array(capacity)
		ffi.copy(array, self[name], old * 4)
		self[name] = array
	end

	local used = UInt8Array(capacity)
	ffi.copy(used, self.used, old)
	self.used = used
	local free_nodes = UInt32Array(capacity)
	ffi.copy(free_nodes, self.free_nodes, self.free_top * 4)
	self.free_nodes = free_nodes

	for i = capacity - 1, old, -1 do
		self.free_top = self.free_top + 1
		free_nodes[self.free_top - 1] = i
	end

	self.node_capacity = capacity
end

local function insert_free(self, size, offset)
	local bin = float_round_down(size)
	local top, leaf = rshift(bin, 3), band(bin, 7)

	if self.bin_head[bin] == UNUSED then
		self.used_bins[top] = bor(self.used_bins[top], lshift(1, leaf))
		self.used_bins_top = bor(self.used_bins_top, lshift(1, top))
	end

	if self.free_top == 0 then grow_nodes(self) end

	self.free_top = self.free_top - 1
	local node = self.free_nodes[self.free_top]
	local head = self.bin_head[bin]
	self.offset[node] = offset
	self.size[node] = size
	self.bin_prev[node] = UNUSED
	self.bin_next[node] = head
	self.near_prev[node] = UNUSED
	self.near_next[node] = UNUSED
	self.used[node] = 0

	if head ~= UNUSED then self.bin_prev[head] = node end

	self.bin_head[bin] = node
	self.free_storage = self.free_storage + size
	return node
end

local function remove_free(self, node)
	local prev, next = self.bin_prev[node], self.bin_next[node]

	if prev ~= UNUSED then
		self.bin_next[prev] = next

		if next ~= UNUSED then self.bin_prev[next] = prev end
	else
		local bin = float_round_down(self.size[node])
		local top, leaf = rshift(bin, 3), band(bin, 7)
		self.bin_head[bin] = next

		if next ~= UNUSED then
			self.bin_prev[next] = UNUSED
		else
			self.used_bins[top] = band(self.used_bins[top], bnot(lshift(1, leaf)))

			if self.used_bins[top] == 0 then
				self.used_bins_top = band(self.used_bins_top, bnot(lshift(1, top)))
			end
		end
	end

	self.free_nodes[self.free_top] = node
	self.free_top = self.free_top + 1
	self.free_storage = self.free_storage - self.size[node]
end

function OffsetAllocator.New(size)
	assert(size > 0 and size <= MAX_SIZE, "offset allocator size out of range")
	local self = setmetatable({}, OffsetAllocator)
	self.node_capacity = 256

	for _, name in ipairs{
		"offset",
		"size",
		"bin_prev",
		"bin_next",
		"near_prev",
		"near_next",
		"free_nodes",
	} do
		self[name] = UInt32Array(self.node_capacity)
	end

	self.used = UInt8Array(self.node_capacity)
	self.bin_head = UInt32Array(NUM_LEAF_BINS)
	self.used_bins = UInt32Array(NUM_TOP_BINS)
	self.used_bins_top = 0
	self.free_storage = 0
	self.free_top = 0
	self.Size = size

	for i = 0, NUM_LEAF_BINS - 1 do
		self.bin_head[i] = UNUSED
	end

	for i = self.node_capacity - 1, 0, -1 do
		self.free_nodes[self.free_top] = i
		self.free_top = self.free_top + 1
	end

	self.tail = insert_free(self, size, 0)
	return self
end

function OffsetAllocator:Alloc(size)
	assert(size > 0 and size <= MAX_SIZE, "offset allocator request out of range")
	local min_bin = float_round_up(size)
	local top = rshift(min_bin, 3)
	local leaf

	if top < NUM_TOP_BINS and band(self.used_bins_top, lshift(1, top)) ~= 0 then
		leaf = lowest_bit_from(self.used_bins[top], band(min_bin, 7))
	end

	if not leaf then
		if top + 1 >= NUM_TOP_BINS then return nil end

		top = lowest_bit_from(self.used_bins_top, top + 1)

		if not top then return nil end

		leaf = highest_bit(band(self.used_bins[top], -self.used_bins[top]))
	end

	local bin = bor(lshift(top, 3), leaf)
	local node = self.bin_head[bin]
	local total = self.size[node]
	self.size[node] = size
	self.used[node] = 1
	local next = self.bin_next[node]
	self.bin_head[bin] = next
	self.free_storage = self.free_storage - total

	if next ~= UNUSED then
		self.bin_prev[next] = UNUSED
	else
		self.used_bins[top] = band(self.used_bins[top], bnot(lshift(1, leaf)))

		if self.used_bins[top] == 0 then
			self.used_bins_top = band(self.used_bins_top, bnot(lshift(1, top)))
		end
	end

	local rest = total - size

	if rest > 0 then
		local offset = self.offset[node]
		local rest_node = insert_free(self, rest, offset + size)
		local after = self.near_next[node]

		if after ~= UNUSED then self.near_prev[after] = rest_node end

		self.near_prev[rest_node] = node
		self.near_next[rest_node] = after
		self.near_next[node] = rest_node

		if self.tail == node then self.tail = rest_node end
	end

	return self.offset[node], node
end

function OffsetAllocator:Free(node)
	assert(self.used[node] == 1, "offset allocator node is not allocated")
	local offset, size = self.offset[node], self.size[node]
	local prev, next = self.near_prev[node], self.near_next[node]
	local was_tail = self.tail == node

	if prev ~= UNUSED and self.used[prev] == 0 then
		offset = self.offset[prev]
		size = size + self.size[prev]
		prev = self.near_prev[prev]
		remove_free(self, self.near_prev[node])
	end

	if next ~= UNUSED and self.used[next] == 0 then
		size = size + self.size[next]
		was_tail = was_tail or self.tail == next
		local after = self.near_next[next]
		remove_free(self, next)
		next = after
	end

	self.used[node] = 0
	self.free_nodes[self.free_top] = node
	self.free_top = self.free_top + 1
	local combined = insert_free(self, size, offset)
	self.near_prev[combined] = prev
	self.near_next[combined] = next

	if next ~= UNUSED then self.near_prev[next] = combined end

	if prev ~= UNUSED then self.near_next[prev] = combined end

	if was_tail then self.tail = combined end
end

function OffsetAllocator:Grow(extra)
	assert(
		extra > 0 and self.Size + extra <= MAX_SIZE,
		"offset allocator growth out of range"
	)

	if self.free_top == 0 then grow_nodes(self) end

	self.free_top = self.free_top - 1
	local node = self.free_nodes[self.free_top]
	self.offset[node] = self.Size
	self.size[node] = extra
	self.used[node] = 1
	self.near_prev[node] = self.tail
	self.near_next[node] = UNUSED
	self.near_next[self.tail] = node
	self.tail = node
	self.Size = self.Size + extra
	self:Free(node)
end

function OffsetAllocator:GetSize(node)
	return self.size[node]
end

function OffsetAllocator:GetFree()
	local largest = 0

	if self.used_bins_top ~= 0 then
		local top = highest_bit(self.used_bins_top)
		local leaf = highest_bit(self.used_bins[top])
		largest = float_to_size(bor(lshift(top, 3), leaf))
	end

	return self.free_storage, largest
end

return OffsetAllocator
