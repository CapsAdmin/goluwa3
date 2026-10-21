local startup = import("goluwa/startup.lua")
local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local render = import("goluwa/render/render.lua")
local Buffer = import("goluwa/render/vulkan/internal/buffer.lua")
local render_stats = import("goluwa/render/stats.lua")
local BatchTable = objects.CreateTemplate("render3d_batch_table")
local UInt64Ptr = ffi.typeof("uint64_t *")
local REFRESH_WINDOW = 4
local WEAK_VALUES = {__mode = "v"}
local WEAK_KEYS = {__mode = "k"}

function BatchTable.New(config)
	return BatchTable:CreateObject{
		label = config.label,
		record_type = config.record_type,
		record_size = ffi.sizeof(config.record_type),
		write_record = config.write_record,
		shared_records = config.shared_records,
		changes = config.changes,
		per_frame = config.per_frame,
		capacity = 0,
		buffers = {},
		synced = {},
		written = {},
		write_serial = 0,
		write_animated = config.write_animated,
		animation_version = config.animation_version,
		versions = {},
		batch_at = setmetatable({}, WEAK_VALUES),
		material_at = setmetatable({}, WEAK_VALUES),
		written_count = 0,
		material_batches = setmetatable({}, WEAK_KEYS),
		copy_sources = setmetatable({}, WEAK_KEYS),
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

local function write_batch_record(self, pipeline, context, index, batch, serial)
	local record = self.records[index - 1]
	local addresses = ffi.cast(UInt64Ptr, record.addresses)
	local mesh = batch.mesh

	local material = batch.material

	if mesh:IsValid() then
		local sources = self.shared_records and material and self.copy_sources[material]
		local source = sources and sources[mesh]

		if
			source and
			self.batch_at[source] and
			self.batch_at[source].first_polygon3d == batch.first_polygon3d and
			self.versions[source] == (material.property_version or -1) and
			source ~= index
		then
			ffi.copy(record, self.records[source - 1], self.record_size)
			addresses = ffi.cast(UInt64Ptr, record.addresses)
		else
			self.write_record(context, pipeline, record, batch)

			if self.shared_records and material then
				if not sources then
					sources = setmetatable({}, WEAK_KEYS)
					self.copy_sources[material] = sources
				end

				sources[mesh] = index
			end
		end

		addresses[0] = mesh:GetVertexBufferAddress()
		addresses[1] = mesh:GetIndexBufferAddress()
		record.index_is_32 = mesh.index_buffer and mesh.index_buffer:GetIndexType() == "uint32" and 1 or 0
	else
		addresses[0] = 0
		addresses[1] = 0
	end

	local old_material = self.material_at[index]

	if old_material ~= material then
		local material_batches = self.material_batches
		local set = old_material and material_batches[old_material]

		if set then set[index] = nil end

		if material then
			set = material_batches[material]

			if not set then
				set = {}
				material_batches[material] = set
			end

			set[index] = true
		end

		self.material_at[index] = material
	end

	self.batch_at[index] = batch
	self.versions[index] = material and material.property_version or -1
	self.written[index] = serial
	self.animated_batches[index] = material ~= nil and material:HasVertexAnimation() or nil
end

local function forget_batch_record(self, index)
	local old_material = self.material_at[index]
	local set = old_material and self.material_batches[old_material]

	if set then set[index] = nil end

	self.material_at[index] = nil
	self.batch_at[index] = nil
	self.versions[index] = nil
	self.animated_batches[index] = nil
end

function BatchTable:Update(pipeline, batches, batch_serial, submission, context)
	local slot = self.per_frame and render.GetCurrentFrame() or 1
	local version = objects.version_counter
	local animation_version = self.animation_version()
	local release_serial = Buffer.address_release_serial
	local resync = self.batch_serial ~= batch_serial or self.address_release_serial ~= release_serial

	if
		not resync and
		self.submission == submission and
		self.material_version == version and
		self.written_animation_version == animation_version and
		self.buffers[slot]
	then
		return self.buffers[slot]:GetDeviceAddress()
	end

	local count = #batches
	local grown = false

	if self.capacity < count then
		self:RemoveBuffers()
		local capacity = math.max(math.ceil(count * 1.5), 1)
		local records = ffi.typeof("$[?]", self.record_type)(capacity)

		if self.records then
			ffi.copy(records, self.records, self.written_count * self.record_size)
		end

		self.capacity = capacity
		self.records = records
		grown = true
		resync = true
	end

	local versions = self.versions
	local written = self.written
	local material_batches = self.material_batches
	local animated_batches = self.animated_batches
	local serial = self.write_serial + 1
	self.write_serial = serial

	local changes = self.changes

	if
		resync and
		changes and
		not grown and
		self.address_release_serial == release_serial and
		self.written_count > 0 and
		batch_serial - self.batch_serial < changes.size
	then
		local batch_at = self.batch_at
		local log = changes.log
		local size = changes.size

		for change = self.batch_serial + 1, batch_serial do
			local i = log[change % size]
			local batch = batches[i]

			if batch_at[i] ~= batch then write_batch_record(self, pipeline, context, i, batch, serial) end
		end

		self.written_count = count
	elseif resync then
		local started = startup.Start()
		local batch_at = self.batch_at
		local check_addresses = self.address_release_serial ~= release_serial
		local addresses = ffi.cast(UInt64Ptr, self.records)
		local stride = self.record_size / 8
		local offset = ffi.offsetof(self.record_type, "addresses") / 8
		local expected = {}

		for i = 1, count do
			local batch = batches[i]
			local stale = batch_at[i] ~= batch

			if not stale and check_addresses then
				local mesh = batch.mesh
				local pair = expected[mesh]

				if not pair then
					if mesh:IsValid() then
						pair = {mesh:GetVertexBufferAddress(), mesh:GetIndexBufferAddress()}
					else
						pair = {0, 0}
					end

					expected[mesh] = pair
				end

				local base = (i - 1) * stride + offset
				stale = addresses[base] ~= pair[1] or addresses[base + 1] ~= pair[2]
			end

			if stale then write_batch_record(self, pipeline, context, i, batch, serial) end
		end

		for i = count + 1, self.written_count do
			forget_batch_record(self, i)
		end

		self.written_count = count

		if grown and not startup.ready_time then
			startup.Add("render pass: gbuffer batch rewrite", started)
		end
	end

	if version - self.material_version >= objects.VERSION_LOG_SIZE then
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
			local set = material and material_batches[material]

			if set then
				for i in pairs(set) do
					if versions[i] ~= material.property_version then
						write_batch_record(self, pipeline, context, i, batches[i], serial)
					end
				end
			end
		end
	end

	if not grown then
		local cursor = self.cursor

		if cursor > count then cursor = 1 end

		for i = cursor, math.min(cursor + REFRESH_WINDOW - 1, count) do
			write_batch_record(self, pipeline, context, i, batches[i], serial)
		end

		self.cursor = cursor + REFRESH_WINDOW
	end

	if self.written_animation_version ~= animation_version then
		local write_animated = self.write_animated

		for i in pairs(animated_batches) do
			if write_animated then
				write_animated(context, pipeline, self.records[i - 1], batches[i])
			else
				write_batch_record(self, pipeline, context, i, batches[i], serial)
			end

			written[i] = serial
		end

		self.written_animation_version = animation_version
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
	self.address_release_serial = release_serial
	return buffer:GetDeviceAddress()
end

return BatchTable:Register()
