local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local store = {}
local Table = {}
Table.__index = Table
-- buffers that were replaced by a bigger one stay alive until the frames in flight that may read them are done
local retired = {}
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
		ffi.copy(ptr, self.ptr, self.capacity * self.row_size)
		retired[#retired + 1] = {buffer = self.buffer, frame = system.GetFrameNumber()}
	end

	self.buffer = buffer
	self.ptr = ptr
	self.capacity = capacity
	self.generation = self.generation + 1

	if self.on_grow then self.on_grow(self) end
end

-- rows are zeroed when they are freed, so an unwritten or freed row reads as all zero
function Table:Alloc()
	local row

	if self.free_count > 0 then
		row = self.free[self.free_count]
		self.free[self.free_count] = nil
		self.free_count = self.free_count - 1
	else
		row = self.count
		self.count = row + 1
		self:Reserve(self.count)
	end

	self.live = self.live + 1
	return row
end

function Table:Free(row)
	ffi.fill(self.ptr + row, self.row_size)
	self.free_count = self.free_count + 1
	self.free[self.free_count] = row
	self.live = self.live - 1
end

function Table:Get()
	return self.ptr
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

	for i = #retired, 1, -1 do
		if retired[i].frame <= frame - RETIRE_FRAMES then
			retired[i].buffer:Remove()
			table.remove(retired, i)
		end
	end
end

return store
