local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local render = import("goluwa/render/render.lua")
local Buffer = import("goluwa/render/vulkan/internal/buffer.lua")
local BatchTable = objects.CreateTemplate("render3d_batch_table")
local UInt64Ptr = ffi.typeof("uint64_t *")
-- records rewritten per update when nothing structural changed, which catches
-- material edits and texture indices changing as textures load within a few
-- updates
local REFRESH_WINDOW = 256

-- The records a multi-draw pipeline indexes with gl_DrawID, one per batch in a
-- gpu_culling dataset. Texture indices are per pipeline, so each pipeline needs
-- its own table. The record type starts with the mesh's buffer addresses
-- and index type, write_record(context, pipeline, record, batch) fills the rest.
--
-- A cpu copy is rewritten and copied whole to a gpu buffer. per_frame keeps a
-- buffer per frame in flight for pipelines drawn in the main frame. Without it
-- the caller must know the gpu is done with the buffer before the next update,
-- like shadow maps that wait on their own fence.
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

-- Rewrites every record when the dataset's batches changed (batch_serial) or
-- when a buffer whose address a record may hold went away. Updating again with
-- the same submission returns the same buffer's address.
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
			-- the shader skips batches without a vertex buffer
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
	-- read after the old buffers above were removed
	self.address_release_serial = Buffer.address_release_serial
	return buffer:GetDeviceAddress()
end

return BatchTable:Register()
