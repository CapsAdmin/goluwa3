local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local render = import("goluwa/render/render.lua")
local Buffer = import("goluwa/render/vulkan/internal/buffer.lua")
local BatchTable = objects.CreateTemplate("render3d_batch_table")
local UInt64Ptr = ffi.typeof("uint64_t *")
local REFRESH_WINDOW = 256

function BatchTable.New(config)
	return BatchTable:CreateObject{
		label = config.label,
		record_type = config.record_type,
		record_size = ffi.sizeof(config.record_type),
		write_record = config.write_record,
		per_frame = config.per_frame,
		capacity = 0,
		buffers = {},
		cursor = 1,
	}
end

function BatchTable:RemoveBuffers()
	for i, buffer in pairs(self.buffers) do
		buffer:Remove()
		self.buffers[i] = nil
	end
end

function BatchTable:OnRemove()
	self:RemoveBuffers()
end

function BatchTable:Update(pipeline, batches, batch_serial, submission, context)
	local slot = self.per_frame and render.GetCurrentFrame() or 1
	local full = self.batch_serial ~= batch_serial or
		self.address_release_serial ~= Buffer.address_release_serial

	if not full and self.submission == submission and self.buffers[slot] then
		return self.buffers[slot]:GetDeviceAddress()
	end

	local count = #batches

	if self.capacity < count then
		self:RemoveBuffers()
		self.capacity = math.max(math.ceil(count * 1.5), 1)
		self.records = ffi.typeof("$[?]", self.record_type)(self.capacity)
		full = true
	end

	local first, last = 1, count

	if full then
		self.cursor = 1
	else
		first = self.cursor

		if first > last then first = 1 end

		last = math.min(first + REFRESH_WINDOW - 1, last)
		self.cursor = last + 1
	end

	local write_record = self.write_record

	for i = first, last do
		local batch = batches[i]
		local record = self.records[i - 1]
		local addresses = ffi.cast(UInt64Ptr, record.addresses)
		local mesh = batch.mesh

		if mesh:IsValid() then
			addresses[0] = mesh:GetVertexBufferAddress()
			addresses[1] = mesh:GetIndexBufferAddress()
			record.index_is_32 = mesh.index_buffer and mesh.index_buffer:GetIndexType() == "uint32" and 1 or 0
			write_record(context, pipeline, record, batch)
		else
			addresses[0] = 0
			addresses[1] = 0
		end
	end

	local buffer = self.buffers[slot]

	if not buffer then
		buffer = render.CreateBuffer{
			byte_size = self.capacity * self.record_size,
			buffer_usage = {"storage_buffer", "shader_device_address"},
			memory_property = {"host_visible", "host_coherent"},
			label = self.label,
		}
		self.buffers[slot] = buffer
	end

	buffer:CopyData(self.records, count * self.record_size)
	self.submission = submission
	self.batch_serial = batch_serial
	self.address_release_serial = Buffer.address_release_serial
	return buffer:GetDeviceAddress()
end

return BatchTable:Register()
