local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local render = import("goluwa/render/render.lua")
local Buffer = import("goluwa/render/vulkan/internal/buffer.lua")
local render_stats = import("goluwa/render/stats.lua")
local BatchTable = objects.CreateTemplate("render3d_batch_table")
local UInt64Ptr = ffi.typeof("uint64_t *")
local REFRESH_WINDOW = 4

function BatchTable.New(config)
	return BatchTable:CreateObject{
		label = config.label,
		record_type = config.record_type,
		record_size = ffi.sizeof(config.record_type),
		write_record = config.write_record,
		per_frame = config.per_frame,
		capacity = 0,
		buffers = {},
		synced = {},
		written = {},
		write_serial = 0,
		write_animated = config.write_animated,
		versions = {},
		material_batches = setmetatable({}, {__mode = "k"}),
		animated_batches = {},
		material_version = objects.version_counter,
		cursor = 1,
	}
end

function BatchTable:RemoveBuffers()
	for i, buffer in pairs(self.buffers) do
		buffer:Remove()
		self.buffers[i] = nil
		self.synced[i] = nil
	end
end

function BatchTable:OnRemove()
	self:RemoveBuffers()
end

-- writes a batch's record in full and notes what the record was written from
local function write_batch_record(self, pipeline, context, index, batch, serial)
	local record = self.records[index - 1]
	local addresses = ffi.cast(UInt64Ptr, record.addresses)
	local mesh = batch.mesh

	if mesh:IsValid() then
		addresses[0] = mesh:GetVertexBufferAddress()
		addresses[1] = mesh:GetIndexBufferAddress()
		record.index_is_32 = mesh.index_buffer and mesh.index_buffer:GetIndexType() == "uint32" and 1 or 0
		self.write_record(context, pipeline, record, batch)
	else
		addresses[0] = 0
		addresses[1] = 0
	end

	local material = batch.material
	self.versions[index] = material and material.property_version or -1
	self.written[index] = serial
	self.animated_batches[index] = material ~= nil and material:HasVertexAnimation() or nil
end

-- a record is written when its batch is new or the material of the batch changed, found in the log of the objects
-- that were stamped since the last update. a batch of an animated material only has the part that moves written
-- every update, and a few records get written in full each update in case something changed that no property
-- version saw. each frame's buffer gets the records that changed since it was last written, kept mapped
function BatchTable:Update(pipeline, batches, batch_serial, submission, context)
	local slot = self.per_frame and render.GetCurrentFrame() or 1
	local version = objects.version_counter
	local full = self.batch_serial ~= batch_serial or
		self.address_release_serial ~= Buffer.address_release_serial

	if
		not full and
		self.submission == submission and
		self.material_version == version and
		self.buffers[slot]
	then
		return self.buffers[slot]:GetDeviceAddress()
	end

	local count = #batches

	if self.capacity < count then
		self:RemoveBuffers()
		self.capacity = math.max(math.ceil(count * 1.5), 1)
		self.records = ffi.typeof("$[?]", self.record_type)(self.capacity)
		self.versions = {}
		self.written = {}
		full = true
	end

	local versions = self.versions
	local written = self.written
	local material_batches = self.material_batches
	local animated_batches = self.animated_batches
	local serial = self.write_serial + 1
	self.write_serial = serial

	if full then
		table.clear(material_batches)
		table.clear(animated_batches)

		for i = 1, count do
			local batch = batches[i]
			write_batch_record(self, pipeline, context, i, batch, serial)
			local material = batch.material

			if material then
				local list = material_batches[material]

				if not list then
					list = {}
					material_batches[material] = list
				end

				list[#list + 1] = i
			end
		end
	elseif version - self.material_version >= objects.VERSION_LOG_SIZE then
		-- too many materials changed to follow them in the log
		for i = 1, count do
			local batch = batches[i]
			local material = batch.material

			if versions[i] ~= (material and material.property_version or -1) then
				write_batch_record(self, pipeline, context, i, batch, serial)
			end
		end
	else
		local log = objects.version_log
		local log_size = objects.VERSION_LOG_SIZE

		for log_version = self.material_version + 1, version do
			local material = log[log_version % log_size]
			local list = material and material_batches[material]

			if list then
				for j = 1, #list do
					local i = list[j]

					if versions[i] ~= material.property_version then
						write_batch_record(self, pipeline, context, i, batches[i], serial)
					end
				end
			end
		end
	end

	if not full then
		local cursor = self.cursor

		if cursor > count then cursor = 1 end

		for i = cursor, math.min(cursor + REFRESH_WINDOW - 1, count) do
			write_batch_record(self, pipeline, context, i, batches[i], serial)
		end

		self.cursor = cursor + REFRESH_WINDOW
	end

	local write_animated = self.write_animated

	for i in pairs(animated_batches) do
		if write_animated then
			write_animated(context, pipeline, self.records[i - 1], batches[i])
		else
			write_batch_record(self, pipeline, context, i, batches[i], serial)
		end

		written[i] = serial
	end

	local buffer = self.buffers[slot]
	local synced = self.synced[slot]

	if not buffer then
		buffer = render.CreateBuffer{
			byte_size = self.capacity * self.record_size,
			buffer_usage = {"storage_buffer", "shader_device_address"},
			memory_property = {"host_visible", "host_coherent"},
			label = self.label,
		}
		self.buffers[slot] = buffer
		synced = 0
	end

	local record_size = self.record_size
	local mapped = buffer:Map()
	local bytes = ffi.cast("uint8_t *", self.records)
	local run_start = nil
	local uploaded = 0

	for i = 1, count + 1 do
		if i <= count and (written[i] or 0) > synced then
			run_start = run_start or i
		elseif run_start then
			local offset = (run_start - 1) * record_size
			local size = (i - run_start) * record_size
			ffi.copy(mapped + offset, bytes + offset, size)
			uploaded = uploaded + size
			run_start = nil
		end
	end

	if render.stats and uploaded > 0 then render_stats.AddUploadedBytes(uploaded) end

	self.synced[slot] = serial
	self.submission = submission
	self.material_version = version
	self.batch_serial = batch_serial
	self.address_release_serial = Buffer.address_release_serial
	return buffer:GetDeviceAddress()
end

return BatchTable:Register()
