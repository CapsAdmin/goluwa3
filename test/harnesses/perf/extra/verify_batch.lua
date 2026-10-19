-- after BatchTable:Update, every record of the table (every VERIFY_EVERY updates of a table, and after each one that
-- resynced) is compared to one written from scratch. the times of the vertex animation are skipped, the shaders do not read them
local ffi = require("ffi")
local BatchTable = import("goluwa/render3d/batch_table.lua")
local Buffer = import("goluwa/render/vulkan/internal/buffer.lua")
ffi.cdef("int memcmp(const void *a, const void *b, size_t n);")
local UInt64Ptr = ffi.typeof("uint64_t *")
local EVERY = tonumber(os.getenv("VERIFY_EVERY") or "") or 40
local stats = {checked = 0, mismatched = 0, runs = 0, resyncs = 0, tables = {}}
local scratch = {}
local counters = {}
local reported = false
local enabled = false
local orig = BatchTable.Update
local TIMES = 16
BatchTable.Update = function(self, pipeline, batches, batch_serial, submission, context)
	local resync = self.batch_serial ~= batch_serial or self.address_release_serial ~= Buffer.address_release_serial
	local address = orig(self, pipeline, batches, batch_serial, submission, context)
	counters[self] = (counters[self] or 0) + 1

	if not enabled or (not resync and counters[self] % EVERY ~= 0) then return address end

	local count = #batches
	local s = scratch[self]

	if not s or s.count < count then
		s = {count = count + 16, records = ffi.typeof("$[?]", self.record_type)(count + 16)}
		scratch[self] = s
	end

	local anim_name = ffi.offsetof(self.record_type, "m_vertex_animation") and "m_vertex_animation" or "anim"
	local anim_offset = ffi.offsetof(self.record_type, anim_name)
	local anim_size = ffi.sizeof(s.records[0][anim_name])
	local live_base = ffi.cast("uint8_t *", self.records)
	local bad = 0

	for i = 1, count do
		local batch = batches[i]
		local record = s.records[i - 1]
		local live = live_base + (i - 1) * self.record_size
		ffi.copy(record, live, self.record_size)
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

		local fresh = ffi.cast("uint8_t *", record)
		local differs = ffi.C.memcmp(live, fresh, anim_offset) ~= 0 or
			ffi.C.memcmp(live + anim_offset + TIMES, fresh + anim_offset + TIMES, self.record_size - anim_offset - TIMES) ~= 0

		if differs and mesh:IsValid() and not (batch.material and batch.material:HasVertexAnimation()) then
			-- a batch that does not animate has its animation block untouched and stale on purpose
			differs = ffi.C.memcmp(live, fresh, anim_offset) ~= 0 or
				ffi.C.memcmp(live + anim_offset + anim_size, fresh + anim_offset + anim_size, self.record_size - anim_offset - anim_size) ~= 0
		end

		if differs then
			bad = bad + 1

			if bad == 1 and not reported then
				reported = true
				local offsets = {}

				for b = 0, self.record_size - 1 do
					if live[b] ~= fresh[b] then offsets[#offsets + 1] = string.format("%d:%02x/%02x", b, live[b], fresh[b]) end
				end

				print(string.format("MP VERIFY first mismatch %s index %d anim_offset %d anim_size %d record_size %d animated %s mesh valid %s differing bytes %s", self.label, i, anim_offset, anim_size, self.record_size, tostring(batch.material and batch.material:HasVertexAnimation()), tostring(mesh:IsValid()), table.concat(offsets, " ", 1, math.min(#offsets, 30))))
			end
		end
	end

	stats.checked = stats.checked + count
	stats.mismatched = stats.mismatched + bad
	stats.runs = stats.runs + 1
	stats.resyncs = stats.resyncs + (resync and 1 or 0)
	local t = stats.tables[self.label] or {0, 0}
	stats.tables[self.label] = t
	t[1] = t[1] + 1
	t[2] = t[2] + bad

	if bad > 0 then print(string.format("MP VERIFY mismatch %s: %d of %d records%s", self.label, bad, count, resync and " (after a resync)" or "")) end

	return address
end
function _G.MP_RESET() enabled = true stats = {checked = 0, mismatched = 0, runs = 0, resyncs = 0, tables = {}} end
function _G.MP_REPORT()
	print(string.format("MP VERIFY %d verifications (%d after a resync), %d records checked, %d mismatched", stats.runs, stats.resyncs, stats.checked, stats.mismatched))
	for label, t in pairs(stats.tables) do print(string.format("MP VERIFY   %-50s %4d runs, %d mismatched", label, t[1], t[2])) end
end
