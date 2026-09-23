local objects = import("goluwa/objects/objects.lua")
local DescriptorPool = import("goluwa/render/vulkan/internal/descriptor_pool.lua")
local InternalRayTracingPipeline = import("goluwa/render/vulkan/internal/ray_tracing_pipeline.lua")
local common = import("goluwa/render/vulkan/pipeline_common.lua")
local RayTracingPipeline = objects.CreateTemplate("render_ray_tracing_pipeline")

local function pool_sizes_from_bindings(descriptor_sets)
	local counts = {}

	for _, bindings in ipairs(descriptor_sets or {}) do
		for _, ds in ipairs(bindings) do
			local type_name = ds.type
			counts[type_name] = (counts[type_name] or 0) + (ds.count or 1)
		end
	end

	local out = {}

	for type_name, count in pairs(counts) do
		out[#out + 1] = {type = type_name, count = count}
	end

	return out
end

function RayTracingPipeline.New(device, config)
	local internal = InternalRayTracingPipeline.New(
		device,
		{
			stages = config.stages,
			descriptor_sets = config.descriptor_sets,
			max_recursion_depth = config.max_recursion_depth,
			max_ray_payload_size = config.max_ray_payload_size,
			push_constants_size = config.push_constants_size,
		}
	)
	local set_count = config.DescriptorSetCount or 1
	local pool_sizes = pool_sizes_from_bindings(config.descriptor_sets)
	local set_layout = internal.set_layouts and internal.set_layouts[1]
	local descriptor_pools = {}
	local descriptor_sets = {}

	if set_layout then
		for frame = 1, set_count do
			descriptor_pools[frame] = DescriptorPool.New(device, pool_sizes, 1)
			descriptor_sets[frame] = {descriptor_pools[frame]:AllocateDescriptorSet(set_layout)}
		end
	end

	local self = RayTracingPipeline:CreateObject{
		vulkan_instance = {device = device},
		config = config,
		internal = internal,
		pipeline_layout = internal.pipeline_layout,
		descriptor_pools = descriptor_pools,
		descriptor_sets = descriptor_sets,
	}
	return self
end

common.bind_descriptor_set_methods(RayTracingPipeline)

function RayTracingPipeline:GetDescriptorSetCount()
	return self.descriptor_sets and #self.descriptor_sets or 0
end

function RayTracingPipeline:DispatchRays(cmd, width, height, depth, frame_index)
	frame_index = frame_index or 1
	local sets = self.descriptor_sets[frame_index]
	self.internal:DispatchRays(cmd, width, height, depth, sets and sets[1])
end

function RayTracingPipeline:OnRemove()
	self.internal:OnRemove()

	for _, pool in ipairs(self.descriptor_pools) do
		if pool then pool:Remove() end
	end
end

return RayTracingPipeline:Register()
