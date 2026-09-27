local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local VertexBuffer = import("goluwa/render/vertex_buffer.lua")
local Buffer = import("goluwa/render/vulkan/internal/buffer.lua")
local render_stats = import("goluwa/render/stats.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local gbuffer_instancing = library()
local FloatPtr = ffi.typeof("float *")
local UInt32Ptr = ffi.typeof("uint32_t *")
local UInt64Ptr = ffi.typeof("uint64_t *")
local INSTANCE_MATRIX_ATTRIBUTES = {
	{
		lua_name = "instance_world",
		lua_type = ffi.typeof("float[16]"),
		offset = 0,
	},
}
local NO_INDEX_BUFFER = {}

local function new_stats()
	return {
		queued_instances = 0,
		instanced_draws = 0,
		singleton_draws = 0,
		frame = 0,
	}
end

-- Draws queued on the cpu this frame are grouped by vertex buffer, index buffer
-- and material upload key. A batch lives on across frames so its instance
-- buffers are reused; it's in the queue while its count is above 0.
local batches = {}
local queued = {}
local queued_count = 0
local live_stats = new_stats()
local last_stats = new_stats()

function gbuffer_instancing.GetStats()
	return last_stats
end

function gbuffer_instancing.Reset()
	for i = 1, queued_count do
		queued[i].count = 0
		queued[i] = nil
	end

	queued_count = 0
	live_stats.queued_instances = 0
	live_stats.instanced_draws = 0
	live_stats.singleton_draws = 0
end

-- returns false when the draw can't be queued and has to be drawn directly
function gbuffer_instancing.Queue(polygon3d, material, world_matrix, prev_world_matrix)
	if not render3d.pipelines.gbuffer_instanced then return false end

	local mesh = polygon3d:GetMesh()

	if not mesh then return false end

	local vertex_buffer = mesh.vertex_buffer:GetBuffer()
	local index_buffer = mesh.index_buffer and mesh.index_buffer:GetBuffer() or NO_INDEX_BUFFER
	local by_index = batches[vertex_buffer]

	if not by_index then
		by_index = {}
		batches[vertex_buffer] = by_index
	end

	local by_material = by_index[index_buffer]

	if not by_material then
		by_material = {}
		by_index[index_buffer] = by_material
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
		queued_count = queued_count + 1
		queued[queued_count] = batch
		batch.mesh = mesh
		batch.material = material
		batch.polygon3d = polygon3d
	end

	local count = batch.count + 1
	batch.count = count
	batch.world_matrices[count] = world_matrix
	batch.prev_world_matrices[count] = prev_world_matrix or world_matrix
	live_stats.queued_instances = live_stats.queued_instances + 1
	return true
end

do
	local function ensure_instance_buffers(batch, instance_count)
		local capacity = batch.instance_capacity or 0

		if capacity >= instance_count then return end

		capacity = math.max(4, capacity)

		while capacity < instance_count do
			capacity = capacity * 2
		end

		if batch.instance_buffer then
			batch.instance_buffer:Remove()
			batch.prev_instance_buffer:Remove()
		end

		batch.instance_buffer = VertexBuffer.New(capacity, INSTANCE_MATRIX_ATTRIBUTES, "render3d gbuffer instances")
		batch.prev_instance_buffer = VertexBuffer.New(capacity, INSTANCE_MATRIX_ATTRIBUTES, "render3d gbuffer prev instances")
		batch.instance_buffers = {batch.instance_buffer, batch.prev_instance_buffer}
		batch.instance_capacity = capacity
	end

	function gbuffer_instancing.Flush()
		for i = 1, queued_count do
			local batch = queued[i]
			local count = batch.count

			if count == 1 then
				live_stats.singleton_draws = live_stats.singleton_draws + 1
				render3d.SetWorldMatrix(batch.world_matrices[1], batch.prev_world_matrices[1])
				render3d.SetCurrentPolygon3D(batch.polygon3d)
				render3d.SetMaterial(batch.material)
				render3d.UploadGBufferConstants()
				batch.polygon3d:Draw()
			elseif batch.mesh:IsValid() then
				live_stats.instanced_draws = live_stats.instanced_draws + 1
				ensure_instance_buffers(batch, count)
				local instance_buffer = batch.instance_buffer
				local prev_instance_buffer = batch.prev_instance_buffer
				local ptr = ffi.cast(FloatPtr, instance_buffer.data)
				local prev_ptr = ffi.cast(FloatPtr, prev_instance_buffer.data)

				for j = 1, count do
					batch.world_matrices[j]:CopyToFloatPointer(ptr + (j - 1) * 16)
					batch.prev_world_matrices[j]:CopyToFloatPointer(prev_ptr + (j - 1) * 16)
				end

				instance_buffer.buffer:CopyData(instance_buffer.data, count * instance_buffer.stride)
				prev_instance_buffer.buffer:CopyData(prev_instance_buffer.data, count * prev_instance_buffer.stride)
				render3d.SetCurrentPolygon3D(batch.polygon3d)
				render3d.SetMaterial(batch.material)
				render3d.UploadInstancedGBufferConstants()
				batch.mesh:DrawInstanced(render.GetCommandBuffer(), count, batch.instance_buffers)
			end
		end

		last_stats.queued_instances = live_stats.queued_instances
		last_stats.instanced_draws = live_stats.instanced_draws
		last_stats.singleton_draws = live_stats.singleton_draws
		last_stats.frame = system.GetFrameNumber()
		gbuffer_instancing.Reset()
	end
end

do
	-- The multi-draw records, one table per pipeline since texture indices are per
	-- pipeline. A cpu copy is rewritten and copied to the frame's own buffer, which
	-- the gpu is done with once the frame's fence was waited on. Every record is
	-- rewritten when a batch got a new mesh or material, or when a buffer whose
	-- address a record may hold went away. Otherwise a window of records is, which
	-- catches material edits and texture indices within a few frames.
	local BATCH_REFRESH_WINDOW = 256
	local batch_tables = setmetatable({}, {__mode = "k"})

	local function update_batch_table(pipeline, batches, batch_serial)
		local batch_table = batch_tables[pipeline]
		local frame_index = render.GetCurrentFrame()
		local full = not batch_table or
			batch_table.batch_serial ~= batch_serial or
			batch_table.address_release_serial ~= Buffer.address_release_serial

		if not full and batch_table.frame_number == system.GetFrameNumber() then
			return batch_table.buffers[frame_index]
		end

		if not batch_table or batch_table.capacity < #batches then
			if batch_table then
				for _, buffer in pairs(batch_table.buffers) do
					buffer:Remove()
				end
			end

			local record_type = model_pipeline.GetPBRBatchRecordType()
			local capacity = math.max(math.ceil(#batches * 1.5), 1)
			batch_table = {
				capacity = capacity,
				record_size = ffi.sizeof(record_type),
				records = ffi.typeof("$[?]", record_type)(capacity),
				buffers = {},
			}
			batch_tables[pipeline] = batch_table
			full = true
		end

		local first, last = 1, #batches

		if full then
			batch_table.cursor = 1
		else
			first = batch_table.cursor

			if first > last then first = 1 end

			last = math.min(first + BATCH_REFRESH_WINDOW - 1, last)
			batch_table.cursor = last + 1
		end

		for i = first, last do
			local batch = batches[i]
			local record = batch_table.records[i - 1]
			local addresses = ffi.cast(UInt64Ptr, record.addresses)
			local mesh = batch.mesh

			if mesh:IsValid() then
				addresses[0] = mesh:GetVertexBufferAddress()
				addresses[1] = mesh:GetIndexBufferAddress()
				record.index_is_32 = mesh.index_buffer and mesh.index_buffer:GetIndexType() == "uint32" and 1 or 0
				render3d.SetCurrentPolygon3D(batch.first_polygon3d)
				render3d.SetMaterial(batch.material)
				model_pipeline.WritePBRBatchRecord(pipeline, record)
			else
				-- the shader skips batches without a vertex buffer
				addresses[0] = 0
				addresses[1] = 0
			end
		end

		local buffer = batch_table.buffers[frame_index]

		if not buffer then
			buffer = render.CreateBuffer{
				byte_size = batch_table.capacity * batch_table.record_size,
				buffer_usage = {"storage_buffer", "shader_device_address"},
				memory_property = {"host_visible", "host_coherent"},
				label = "render3d_gbuffer_batches",
			}
			batch_table.buffers[frame_index] = buffer
		end

		buffer:CopyData(batch_table.records, #batches * batch_table.record_size)
		batch_table.frame_number = system.GetFrameNumber()
		batch_table.batch_serial = batch_serial
		-- read after the old buffers above were removed
		batch_table.address_release_serial = Buffer.address_release_serial
		return buffer
	end

	local result = {}

	-- Draws every gpu culled static batch with two indirect multi-draws, one per
	-- cull mode: the cull wrote each batch's command into the half for its
	-- material's sidedness with its visible instance count, leaving the other at
	-- zero instances.
	function gbuffer_instancing.DrawGPUCulled(cull_result)
		result.drew_any = false
		result.submitted_entry_count = 0
		result.draw_call_count = 0
		result.active_batch_count = 0
		result.total_batch_count = 0
		local pipeline = render3d.pipelines.gbuffer_multi_draw

		if not (cull_result and pipeline and gpu_culling.IsCullResultCurrent(cull_result)) then
			return result
		end

		local dataset = gpu_culling.GetSceneDataset()
		local frame_buffers = gpu_culling.GetFrameBuffers()
		local output = frame_buffers and frame_buffers[cull_result.frame_index]
		local batches = dataset and dataset.main_instanced_batches

		if not (output and batches and batches[1]) then return result end

		local cmd = render.GetCommandBuffer()
		local stride = gpu_culling.BATCH_DRAW_COMMAND_SIZE
		local commands = output.visible_batch_indirect_command_buffer
		pipeline.draw_batches_address = update_batch_table(pipeline, batches, dataset.main.batch_serial):GetDeviceAddress()
		pipeline.draw_instances_address = output.visible_instance_vertex_buffer.buffer:GetDeviceAddress()
		pipeline:UploadConstants()
		cmd:SetPolygonMode("fill")
		cmd:SetCullMode(orientation.CULL_MODE)
		cmd:DrawIndirect(commands, 0, #batches, stride)
		cmd:SetCullMode("none")
		cmd:DrawIndirect(commands, output.batch_command_capacity * stride, #batches, stride)
		result.drew_any = true
		result.submitted_entry_count = math.max((cull_result.visible_entry_count or 0) - (cull_result.fallback_visible_entry_count or 0), 0)
		result.draw_call_count = 2
		result.active_batch_count = ffi.cast(UInt32Ptr, output.active_batch_count_buffer:Map())[0]
		result.total_batch_count = #batches
		return result
	end
end

render_stats.RegisterGroup{
	id = "render3d_instancing",
	label = "RENDER3D INSTANCING",
}
render_stats.RegisterField{
	id = "r3d_instanced_draws",
	label = "R3D INST DRAWS",
	group = "render3d_instancing",
	getter = function()
		return last_stats.instanced_draws
	end,
}
render_stats.RegisterField{
	id = "r3d_instanced_singletons",
	label = "R3D INST SINGLE",
	group = "render3d_instancing",
	getter = function()
		return last_stats.singleton_draws
	end,
}
return gbuffer_instancing
