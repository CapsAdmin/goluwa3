local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local vk = import("goluwa/bindings/vk.lua")
local store = {}
local Table = {}
Table.__index = Table
local retired = {}
local tables = setmetatable({}, {__mode = "k"})
local RETIRE_FRAMES = 4
local BufferCopy = ffi.typeof("$[?]", vk.VkBufferCopy)
local staged_tables = setmetatable({}, {__mode = "k"})

function store.CreateTable(config)
	local self = setmetatable({}, Table)
	self.name = config.name
	self.ctype = ffi.typeof(config.ctype)
	self.row_size = ffi.sizeof(self.ctype)
	self.usage = config.usage or {"storage_buffer", "shader_device_address"}
	self.staged = config.staged

	if self.staged then
		self.usage = {unpack(self.usage)}
		self.usage[#self.usage + 1] = "transfer_dst"
		self.ptr_ctype = ffi.typeof("$*", self.ctype)
		staged_tables[self] = true
	end

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
		memory_property = self.staged and {"device_local"} or {"host_visible", "host_coherent"},
		label = "scene_" .. self.name,
	}
	local memory
	local ptr

	if self.staged then
		memory = ffi.new("uint8_t[?]", capacity * self.row_size)
		ptr = ffi.cast(self.ptr_ctype, memory)
	else
		ptr = ffi.cast(ffi.typeof("$*", self.ctype), buffer:Map())
		ffi.fill(ptr, capacity * self.row_size)
	end

	if self.buffer then
		render.GetDevice():WaitIdle()
		ffi.copy(ptr, self.ptr, self.capacity * self.row_size)
		retired[#retired + 1] = {buffer = self.buffer, frame = system.GetFrameNumber()}
	end

	self.buffer = buffer
	self.memory = memory
	self.ptr = ptr
	self.capacity = capacity
	self.generation = self.generation + 1

	if self.staged then
		self.dirty_flags = ffi.new("uint8_t[?]", capacity)
		ffi.fill(self.dirty_flags, capacity, 1)
		self.dirty_min = 0
		self.dirty_max = capacity - 1
	end

	if self.on_grow then self.on_grow(self) end
end

function Table:Touch(row)
	local flags = self.dirty_flags

	if flags[row] == 0 then
		flags[row] = 1

		if row < self.dirty_min then self.dirty_min = row end

		if row > self.dirty_max then self.dirty_max = row end
	end
end

function Table:TouchRange(base, n)
	for row = base, base + n - 1 do
		self:Touch(row)
	end
end

do
	local uploads = {}
	local runs = ffi.new("uint32_t[?]", 2048)
	local run_capacity = 1024
	local regions = BufferCopy(1024)
	local region_capacity = 1024

	local function reserve_upload(bytes)
		local serial = render.frame_serial or 0
		local slot = serial % math.max(render.GetSwapchainImageCount() or 1, 1) + 1
		local upload = uploads[slot]

		if not upload then
			upload = {serial = -1, used = 0, size = 0}
			uploads[slot] = upload
		end

		if upload.serial ~= serial then
			upload.serial = serial
			upload.used = 0
		end

		local offset = bit.band(upload.used + 15, bit.bnot(15))

		if not upload.buffer or offset + bytes > upload.size then
			if upload.buffer then
				retired[#retired + 1] = {buffer = upload.buffer, frame = system.GetFrameNumber()}
			end

			upload.size = math.max(bytes * 2, 4 * 1024 * 1024)
			upload.buffer = render.CreateBuffer{
				byte_size = upload.size,
				buffer_usage = {"transfer_src"},
				memory_property = {"host_visible", "host_coherent"},
				label = "scene_upload",
			}
			upload.ptr = ffi.cast("uint8_t *", upload.buffer:Map())
			offset = 0
		end

		upload.used = offset + bytes

		if upload.used * 4 > upload.size then
			upload.busy_frame = system.GetFrameNumber()
		end

		return upload.buffer, upload.ptr + offset, offset
	end

	function store.TrimUploads(frame)
		for _, upload in pairs(uploads) do
			if
				upload.buffer and
				upload.size > 8 * 1024 * 1024 and
				frame - upload.busy_frame > 600
			then
				retired[#retired + 1] = {buffer = upload.buffer, frame = frame}
				upload.buffer = nil
				upload.size = 0
			end
		end
	end

	local function collect_runs(rows)
		local flags = rows.dirty_flags
		local row = rows.dirty_min
		local last = math.min(rows.dirty_max, rows.capacity - 1)
		local count = 0

		while row <= last do
			if flags[row] ~= 0 then
				local first = row

				while row <= last and flags[row] ~= 0 do
					flags[row] = 0
					row = row + 1
				end

				if count + 1 > run_capacity then
					local grown = ffi.new("uint32_t[?]", run_capacity * 4)
					ffi.copy(grown, runs, run_capacity * 2 * 4)
					runs = grown
					run_capacity = run_capacity * 2
				end

				runs[count * 2] = first
				runs[count * 2 + 1] = row - first
				count = count + 1
			else
				row = row + 1
			end
		end

		rows.dirty_min = rows.capacity
		rows.dirty_max = -1
		return count
	end

	function store.FlushStaged(cmd)
		local barriered = false

		for rows in pairs(staged_tables) do
			if rows.dirty_max >= rows.dirty_min then
				local count = collect_runs(rows)
				local row_size = rows.row_size
				local bytes = 0

				for i = 0, count - 1 do
					bytes = bytes + runs[i * 2 + 1] * row_size
				end

				if count > 0 then
					if not barriered then
						barriered = true
						cmd:PipelineBarrier{srcStage = "all_commands", dstStage = "transfer", memoryBarrier = true}
					end

					if count > region_capacity then
						region_capacity = count * 2
						regions = BufferCopy(region_capacity)
					end

					local buffer, pointer, base = reserve_upload(bytes)
					local source = ffi.cast("uint8_t *", rows.memory)
					local written = 0

					for i = 0, count - 1 do
						local first = runs[i * 2]
						local size = runs[i * 2 + 1] * row_size
						ffi.copy(pointer + written, source + first * row_size, size)
						regions[i].srcOffset = base + written
						regions[i].dstOffset = first * row_size
						regions[i].size = size
						written = written + size
					end

					cmd:CopyBuffer(buffer, rows.buffer, regions, count)
				end
			end
		end

		if barriered then
			cmd:PipelineBarrier{srcStage = "transfer", dstStage = "all_commands", memoryBarrier = true}
		end
	end
end

function Table:Alloc()
	local row

	if self.free_count > 0 then
		row = self.free[self.free_count]
		self.free[self.free_count] = nil
		self.free_count = self.free_count - 1
	elseif self.free_ranges and self.free_ranges[1] then
		local range = self.free_ranges[1]
		row = range.base
		range.base = range.base + 1
		range.n = range.n - 1

		if range.n == 0 then table.remove(self.free_ranges, 1) end
	else
		row = self.count
		self.count = row + 1
		self:Reserve(self.count)
	end

	self.live = self.live + 1
	return row
end

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

local function release_range(self, base, n)
	ffi.fill(self.ptr + base, n * self.row_size)

	if self.staged then self:TouchRange(base, n) end

	local ranges = self.free_ranges

	if not ranges then
		ranges = {}
		self.free_ranges = ranges
	end

	local i = 1

	while ranges[i] and ranges[i].base < base do
		i = i + 1
	end

	local before, after = ranges[i - 1], ranges[i]
	local joins_before = before and before.base + before.n == base
	local joins_after = after and base + n == after.base

	if joins_before and joins_after then
		before.n = before.n + n + after.n
		table.remove(ranges, i)
	elseif joins_before then
		before.n = before.n + n
	elseif joins_after then
		after.base = base
		after.n = after.n + n
	else
		table.insert(ranges, i, {base = base, n = n})
	end

	local last = ranges[#ranges]

	if last.base + last.n == self.count then
		self.count = last.base
		ranges[#ranges] = nil
	end
end

function Table:FreeRange(base, n, immediate)
	self.live = self.live - n

	if immediate then
		release_range(self, base, n)
		return
	end

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
				release_range(self, range.base, range.n)
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

			if self.staged then self:Touch(item.row) end

			self.free_count = self.free_count + 1
			self.free[self.free_count] = item.row
		else
			keep[#keep + 1] = item
		end
	end

	self.pending_free = keep
end

function Table:GetSpans(spans)
	local position = 0
	local rows = 0
	local count = 0

	if self.free_ranges then
		for _, range in ipairs(self.free_ranges) do
			if range.base > position then
				spans[count * 2 + 1] = position
				spans[count * 2 + 2] = range.base - position
				rows = rows + range.base - position
				count = count + 1
			end

			position = range.base + range.n
		end
	end

	if position < self.count then
		spans[count * 2 + 1] = position
		spans[count * 2 + 2] = self.count - position
		rows = rows + self.count - position
		count = count + 1
	end

	return rows, count
end

function Table:Get()
	return self.ptr
end

function Table:Clear()
	ffi.fill(self.ptr, self.capacity * self.row_size)

	if self.staged then
		ffi.fill(self.dirty_flags, self.capacity, 1)
		self.dirty_min = 0
		self.dirty_max = self.capacity - 1
	end

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

	store.TrimUploads(frame)

	for i = #retired, 1, -1 do
		if retired[i].frame <= frame - RETIRE_FRAMES then
			retired[i].buffer:Remove()
			table.remove(retired, i)
		end
	end
end

do
	local BufferCopy = ffi.typeof("$[1]", vk.VkBufferCopy)

	function store.Download(buffer, size)
		local readback = render.CreateBuffer{
			byte_size = size,
			buffer_usage = {"transfer_dst"},
			memory_property = {"host_visible", "host_coherent", "host_cached"},
			label = "scene_store readback",
		}
		local copy = BufferCopy()
		copy[0].size = size
		local cmd = render.GetCommandPool():AllocateCommandBuffer()
		cmd.gpu_timing_disabled = true
		cmd:Begin()
		cmd:PipelineBarrier{
			srcStage = {"compute", "transfer"},
			dstStage = "transfer",
			bufferBarriers = {
				{
					buffer = buffer,
					srcAccessMask = "shader_write",
					dstAccessMask = "transfer_read",
				},
			},
		}
		cmd:CopyBuffer(buffer, readback, copy, 1)
		cmd:End()
		render.SubmitAndWait(cmd)
		cmd:Remove()
		local out = ffi.new("uint8_t[?]", size)
		ffi.copy(out, readback:Map(), size)
		readback:Remove()
		return out
	end
end

return store
