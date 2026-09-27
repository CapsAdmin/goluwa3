local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local render = import("goluwa/render/render.lua")
local VertexBuffer = import("goluwa/render/vertex_buffer.lua")
local InstanceBatcher = objects.CreateTemplate("render3d_instance_batcher")
local FloatPtr = ffi.typeof("float *")
local MATRIX_BYTES = 16 * 4
local INSTANCE_MATRIX_ATTRIBUTES = {
	{
		lua_name = "instance_world",
		lua_type = ffi.typeof("float[16]"),
		offset = 0,
	},
}

-- Groups draws queued between flushes by mesh and material upload key. A
-- group of one is drawn with draw_single(context, batch), a larger one with
-- draw_instanced(context, batch, instance_buffers, first_instance).
--
-- A flush writes the world matrices of every instanced group (and the previous
-- frame's with prev_matrices) into one buffer, after what earlier flushes of the
-- same submission wrote, since the gpu reads all of them later. per_frame keeps
-- a buffer per frame in flight. Without it the caller must know the gpu is done
-- with the previous submission, like shadow maps that wait on their own fence.
function InstanceBatcher.New(config)
	return InstanceBatcher:CreateObject{
		label = config.label,
		prev_matrices = config.prev_matrices,
		per_frame = config.per_frame,
		draw_single = config.draw_single,
		draw_instanced = config.draw_instanced,
		-- mesh -> material upload key -> batch. a batch only holds the mesh while
		-- queued, so removed meshes drop out
		batches = setmetatable({}, {__mode = "k"}),
		queued = {},
		queued_count = 0,
		slots = {},
	}
end

function InstanceBatcher:OnRemove()
	for _, slot in pairs(self.slots) do
		for _, buffer in ipairs(slot.buffers) do
			buffer:Remove()
		end
	end
end

function InstanceBatcher:Queue(polygon3d, mesh, material, world_matrix, prev_world_matrix)
	local by_material = self.batches[mesh]

	if not by_material then
		by_material = {}
		self.batches[mesh] = by_material
	end

	local material_key = material.upload_cache_key or material
	local batch = by_material[material_key]

	if not batch then
		batch = {
			world_matrices = {},
			prev_world_matrices = {},
			count = 0,
		}
		by_material[material_key] = batch
	end

	if batch.count == 0 then
		self.queued_count = self.queued_count + 1
		self.queued[self.queued_count] = batch
		batch.mesh = mesh
		batch.material = material
		batch.polygon3d = polygon3d
	end

	local count = batch.count + 1
	batch.count = count
	batch.world_matrices[count] = world_matrix
	batch.prev_world_matrices[count] = prev_world_matrix or world_matrix
end

function InstanceBatcher:Reset()
	local queued = self.queued

	for i = 1, self.queued_count do
		local batch = queued[i]
		batch.count = 0
		batch.mesh = nil
		batch.material = nil
		batch.polygon3d = nil
		queued[i] = nil
	end

	self.queued_count = 0
end

do
	local function create_buffers(self, slot, capacity)
		local buffers = {VertexBuffer.New(capacity, INSTANCE_MATRIX_ATTRIBUTES, self.label)}

		if self.prev_matrices then
			buffers[2] = VertexBuffer.New(capacity, INSTANCE_MATRIX_ATTRIBUTES, self.label .. " prev")
		end

		slot.buffers = buffers
		slot.capacity = capacity
		slot.used = 0
	end

	-- a slot's buffers may be read by commands recorded earlier in its
	-- submission, so outgrowing them mid submission retires them until the slot
	-- starts its next one
	local function reserve(self, slot, submission, count)
		if slot.submission ~= submission then
			slot.submission = submission
			slot.used = 0

			for i, buffer in ipairs(slot.retired) do
				buffer:Remove()
				slot.retired[i] = nil
			end
		end

		if slot.used + count <= slot.capacity then return end

		for _, buffer in ipairs(slot.buffers) do
			if slot.used == 0 then
				buffer:Remove()
			else
				slot.retired[#slot.retired + 1] = buffer
			end
		end

		create_buffers(self, slot, math.max(64, (slot.used + count) * 2, slot.capacity))
	end

	local function write_matrices(buffer, matrices, first, count)
		local ptr = ffi.cast(FloatPtr, buffer.data) + first * 16

		for i = 1, count do
			matrices[i]:CopyToFloatPointer(ptr + (i - 1) * 16)
		end
	end

	-- submission identifies the gpu submission the draws are recorded into.
	-- returns the number of instanced and single draws
	function InstanceBatcher:Flush(context, submission)
		local queued = self.queued
		local queued_count = self.queued_count
		local instance_count = 0

		for i = 1, queued_count do
			local batch = queued[i]

			if batch.count > 1 then instance_count = instance_count + batch.count end
		end

		local slot

		if instance_count > 0 then
			local slot_index = self.per_frame and render.GetCurrentFrame() or 1
			slot = self.slots[slot_index]

			if not slot then
				slot = {buffers = {}, retired = {}, capacity = 0, used = 0}
				self.slots[slot_index] = slot
			end

			reserve(self, slot, submission, instance_count)
			local first = slot.used
			local cursor = first

			for i = 1, queued_count do
				local batch = queued[i]

				if batch.count > 1 then
					batch.first_instance = cursor
					write_matrices(slot.buffers[1], batch.world_matrices, cursor, batch.count)

					if self.prev_matrices then
						write_matrices(slot.buffers[2], batch.prev_world_matrices, cursor, batch.count)
					end

					cursor = cursor + batch.count
				end
			end

			for _, buffer in ipairs(slot.buffers) do
				buffer.buffer:CopyData(buffer.data + first * MATRIX_BYTES, instance_count * MATRIX_BYTES, first * MATRIX_BYTES)
			end

			slot.used = cursor
		end

		local instanced_draws = 0
		local single_draws = 0

		for i = 1, queued_count do
			local batch = queued[i]

			if batch.mesh:IsValid() then
				if batch.count == 1 then
					single_draws = single_draws + 1
					self.draw_single(context, batch)
				else
					instanced_draws = instanced_draws + 1
					self.draw_instanced(context, batch, slot.buffers, batch.first_instance)
				end
			end
		end

		self:Reset()
		return instanced_draws, single_draws
	end
end

return InstanceBatcher:Register()
