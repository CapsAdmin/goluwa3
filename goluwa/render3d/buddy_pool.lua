local bit = require("bit")
-- a pool of slots handed out as rooms of 2^class, at an offset that is a multiple of their size. a room is made by
-- splitting a free one of a bigger class (or a fresh block of the biggest, from where Top has not reached yet), and a freed room
-- joins its buddy, the room next to it that it was split from, when that one is free too. a free list per class could not do
-- this: the free rooms of one class were no use to a request for another, so a pool that was mostly free held up requests for good
local BuddyPool = {}
BuddyPool.__index = BuddyPool

function BuddyPool.New(size, min_class, max_class)
	assert(size % 2 ^ max_class == 0, "the size of a buddy pool is a whole number of rooms of its biggest class")
	local self = setmetatable({}, BuddyPool)
	self.Size = size
	self.MinClass = min_class
	self.MaxClass = max_class
	-- how far the pool has been handed out for the first time
	self.Top = 0
	self.free_rooms = {}
	self.free_index = {}

	for class = min_class, max_class do
		self.free_rooms[class] = {}
		self.free_index[class] = {}
	end

	return self
end

function BuddyPool:PushFree(offset, class)
	local rooms = self.free_rooms[class]
	rooms[#rooms + 1] = offset
	self.free_index[class][offset] = #rooms
end

function BuddyPool:RemoveFree(offset, class)
	local rooms, index = self.free_rooms[class], self.free_index[class]
	local at = index[offset]
	local last = rooms[#rooms]
	rooms[at] = last
	index[last] = at
	rooms[#rooms] = nil
	index[offset] = nil
end

-- the offset of a room of 2^class slots, nil when there is none
function BuddyPool:Alloc(class)
	local max_class = self.MaxClass
	local from = class

	while from <= max_class and not self.free_rooms[from][1] do
		from = from + 1
	end

	local offset

	if from <= max_class then
		local rooms = self.free_rooms[from]
		offset = rooms[#rooms]
		self:RemoveFree(offset, from)
	else
		if self.Top + 2 ^ max_class > self.Size then return nil end

		offset = self.Top
		self.Top = self.Top + 2 ^ max_class
		from = max_class
	end

	while from > class do
		from = from - 1
		self:PushFree(offset + 2 ^ from, from)
	end

	return offset
end

function BuddyPool:Free(offset, class)
	while class < self.MaxClass do
		local buddy = bit.bxor(offset, 2 ^ class)

		if not self.free_index[class][buddy] then break end

		self:RemoveFree(buddy, class)
		offset = math.min(offset, buddy)
		class = class + 1
	end

	self:PushFree(offset, class)
end

-- how many slots are free in rooms that were handed out and given back, and how many rooms of each class
function BuddyPool:GetFree()
	local total, by_class = 0, {}

	for class = self.MinClass, self.MaxClass do
		by_class[class] = #self.free_rooms[class]
		total = total + #self.free_rooms[class] * 2 ^ class
	end

	return total, by_class
end

return BuddyPool
