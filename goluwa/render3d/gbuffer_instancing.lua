local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local render_stats = import("goluwa/render/stats.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local BatchTable = import("goluwa/render3d/batch_table.lua")
local InstanceBatcher = import("goluwa/render3d/instance_batcher.lua")
local gbuffer_instancing = library()
local UInt32Ptr = ffi.typeof("uint32_t *")
local queued_instances = 0
local last_stats = {
	queued_instances = 0,
	instanced_draws = 0,
	singleton_draws = 0,
	frame = 0,
}

local function draw_single(_, batch)
	render3d.SetWorldMatrix(batch.world_matrices[1], batch.prev_world_matrices[1])
	render3d.SetCurrentPolygon3D(batch.polygon3d)
	render3d.SetMaterial(batch.material)
	render3d.UploadGBufferConstants()
	batch.polygon3d:Draw()
end

local function draw_instanced(_, batch, instance_buffers, first_instance)
	render3d.SetCurrentPolygon3D(batch.polygon3d)
	render3d.SetMaterial(batch.material)
	render3d.UploadInstancedGBufferConstants()
	batch.mesh:DrawInstanced(render.GetCommandBuffer(), batch.count, instance_buffers, nil, 0, 0, first_instance)
end

local batcher = InstanceBatcher.New{
	label = "render3d gbuffer instances",
	prev_matrices = true,
	per_frame = true,
	draw_single = draw_single,
	draw_instanced = draw_instanced,
}

function gbuffer_instancing.GetStats()
	return last_stats
end

function gbuffer_instancing.Reset()
	batcher:Reset()
	queued_instances = 0
end

-- returns false when the draw can't be queued and has to be drawn directly
function gbuffer_instancing.Queue(polygon3d, material, world_matrix, prev_world_matrix)
	if not render3d.pipelines.gbuffer_instanced then return false end

	local mesh = polygon3d:GetMesh()

	if not mesh then return false end

	batcher:Queue(polygon3d, mesh, material, world_matrix, prev_world_matrix)
	queued_instances = queued_instances + 1
	return true
end

function gbuffer_instancing.Flush()
	last_stats.instanced_draws, last_stats.singleton_draws = batcher:Flush(nil, system.GetFrameNumber())
	last_stats.queued_instances = queued_instances
	last_stats.frame = system.GetFrameNumber()
	queued_instances = 0
end

do
	local batch_tables = setmetatable({}, {__mode = "k"})

	local function write_record(_, pipeline, record, batch)
		render3d.SetCurrentPolygon3D(batch.first_polygon3d)
		render3d.SetMaterial(batch.material)
		model_pipeline.WritePBRBatchRecord(pipeline, record)
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
		local batch_table = batch_tables[pipeline]

		if not batch_table then
			batch_table = BatchTable.New{
				label = "render3d_gbuffer_batches",
				record_type = model_pipeline.GetPBRBatchRecordType(),
				write_record = write_record,
				per_frame = true,
			}
			batch_tables[pipeline] = batch_table
		end

		pipeline.draw_batches_address = batch_table:Update(pipeline, batches, dataset.main.batch_serial, system.GetFrameNumber())
		pipeline.draw_instances_address = output.visible_instance_vertex_buffer.buffer:GetDeviceAddress()
		pipeline:UploadConstants()
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
