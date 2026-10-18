local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local store = {}
local Table = {}
Table.__index = Table
-- buffers that were replaced by a bigger one stay alive until the frames in flight that may read them are done
local retired = {}
local tables = setmetatable({}, {__mode = "k"})
local RETIRE_FRAMES = 4

function store.CreateTable(config)
	local self = setmetatable({}, Table)
	self.name = config.name
	self.ctype = ffi.typeof(config.ctype)
	self.row_size = ffi.sizeof(self.ctype)
	self.usage = config.usage or {"storage_buffer", "shader_device_address"}
	self.capacity = 0
	self.count = 0
	self.live = 0
	self.free = {}
	self.free_count = 0
	self.generation = 0
	self.on_grow = config.on_grow
	tables[self] = true
	self:Reserve(config.capacity or 1024)
	return self
end

function Table:Reserve(capacity)
	if capacity <= self.capacity then return end

	capacity = math.max(capacity, math.ceil(self.capacity * 1.5))
	local buffer = render.CreateBuffer{
		byte_size = capacity * self.row_size,
		buffer_usage = self.usage,
		memory_property = {"host_visible", "host_coherent"},
		label = "scene_" .. self.name,
	}
	local ptr = ffi.cast(ffi.typeof("$*", self.ctype), buffer:Map())
	ffi.fill(ptr, capacity * self.row_size)

	if self.buffer then
		-- the descriptors that point at the old buffer are rewritten by the next bind, which a frame in flight does not allow
		render.GetDevice():WaitIdle()
		ffi.copy(ptr, self.ptr, self.capacity * self.row_size)
		retired[#retired + 1] = {buffer = self.buffer, frame = system.GetFrameNumber()}
	end

	self.buffer = buffer
	self.ptr = ptr
	self.capacity = capacity
	self.generation = self.generation + 1

	if self.on_grow then self.on_grow(self) end
end

-- a freed row keeps what it held until the frames that may still read it are done, then it is zeroed and can be given out again
function Table:Alloc()
	local row

	if self.free_count > 0 then
		row = self.free[self.free_count]
		self.free[self.free_count] = nil
		self.free_count = self.free_count - 1
	elseif self.free_ranges and self.free_ranges[1] then
		local range = self.free_ranges[#self.free_ranges]
		row = range.base + range.n - 1
		range.n = range.n - 1

		if range.n == 0 then self.free_ranges[#self.free_ranges] = nil end
	else
		row = self.count
		self.count = row + 1
		self:Reserve(self.count)
	end

	self.live = self.live + 1
	return row
end

-- n rows in a row of their own, for what a gpu pass writes a range of
function Table:AllocRange(n)
	local ranges = self.free_ranges

	if ranges then
		for i, range in ipairs(ranges) do
			if range.n >= n then
				local base = range.base
				range.base = range.base + n
				range.n = range.n - n

				if range.n == 0 then table.remove(ranges, i) end

				self.live = self.live + n

				return base
			end
		end
	end

	local base = self.count
	self.count = base + n
	self:Reserve(self.count)
	self.live = self.live + n
	return base
end

function Table:FreeRange(base, n)
	self.live = self.live - n
	self.pending_ranges = self.pending_ranges or {}
	self.pending_ranges[#self.pending_ranges + 1] = {base = base, n = n, frame = system.GetFrameNumber()}
end

function Table:Free(row)
	self.live = self.live - 1
	self.pending_free = self.pending_free or {}
	self.pending_free[#self.pending_free + 1] = {row = row, frame = system.GetFrameNumber()}
end

function Table:Update(frame)
	local ranges = self.pending_ranges

	if ranges and ranges[1] then
		local keep = {}

		for _, range in ipairs(ranges) do
			if range.frame <= frame - RETIRE_FRAMES then
				ffi.fill(self.ptr + range.base, range.n * self.row_size)
				self.free_ranges = self.free_ranges or {}
				self.free_ranges[#self.free_ranges + 1] = {base = range.base, n = range.n}
			else
				keep[#keep + 1] = range
			end
		end

		self.pending_ranges = keep
	end

	local pending = self.pending_free

	if not pending or not pending[1] then return end

	local keep = {}

	for _, item in ipairs(pending) do
		if item.frame <= frame - RETIRE_FRAMES then
			ffi.fill(self.ptr + item.row, self.row_size)
			self.free_count = self.free_count + 1
			self.free[self.free_count] = item.row
		else
			keep[#keep + 1] = item
		end
	end

	self.pending_free = keep
end

function Table:Get()
	return self.ptr
end

-- every row is unused again, for a table that is rewritten as a whole
function Table:Clear()
	ffi.fill(self.ptr, self.capacity * self.row_size)
	self.count = 0
	self.live = 0
	self.free = {}
	self.free_count = 0
	self.free_ranges = nil
	self.pending_free = nil
	self.pending_ranges = nil
end

function Table:GetBuffer()
	return self.buffer
end

function Table:GetAddress()
	return self.buffer:GetDeviceAddress()
end

function Table:GetSize()
	return self.capacity * self.row_size
end

function store.Update()
	local frame = system.GetFrameNumber()

	for rows in pairs(tables) do
		rows:Update(frame)
	end

	for i = #retired, 1, -1 do
		if retired[i].frame <= frame - RETIRE_FRAMES then
			retired[i].buffer:Remove()
			table.remove(retired, i)
		end
	end
end

return store
