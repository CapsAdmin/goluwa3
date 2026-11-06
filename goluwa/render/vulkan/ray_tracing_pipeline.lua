local objects = import("goluwa/objects/objects.lua")
local DescriptorPool = import("goluwa/render/vulkan/internal/descriptor_pool.lua")
local InternalRayTracingPipeline = import("goluwa/render/vulkan/internal/ray_tracing_pipeline.lua")
local common = import("goluwa/render/vulkan/pipeline_common.lua")
local bindless = import("goluwa/render/vulkan/bindless.lua")
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

common.bind_texture_registry(RayTracingPipeline)

function RayTracingPipeline.New(device, config)
	local set_bindings = config.descriptor_sets
	local bindless_state = bindless.Get(device)
	local shared_set_layouts

	if config.bindless then
		set_bindings = {set_bindings[1], {}}
		shared_set_layouts = {[2] = bindless_state.layout}
	end

	local internal = InternalRayTracingPipeline.New(
		device,
		{
			name = config.name,
			stages = config.stages,
			descriptor_sets = set_bindings,
			shared_set_layouts = shared_set_layouts,
			max_recursion_depth = config.max_recursion_depth,
			max_ray_payload_size = config.max_ray_payload_size,
			push_constants_size = config.push_constants_size,
		}
	)
	local set_count = config.DescriptorSetCount or 1
	local set_layouts = internal.set_layouts or {}
	local descriptor_pools = {}
	local descriptor_sets = {}
	local binding_counts = {}

	for set_index, bindings in ipairs(set_bindings) do
		binding_counts[set_index - 1] = {}

		for _, binding in ipairs(bindings) do
			binding_counts[set_index - 1][binding.binding_index] = binding.count or 1
		end
	end

	if config.bindless then binding_counts[1] = bindless_state.binding_counts end

	if #set_layouts > 0 then
		local own_set_count = #set_layouts - (config.bindless and 1 or 0)
		local pool_sizes = pool_sizes_from_bindings({set_bindings[1]})

		for _, pool_size in ipairs(pool_sizes) do
			pool_size.count = pool_size.count * set_count
		end

		if not pool_sizes[1] then pool_sizes[1] = {type = "sampler", count = 1} end

		descriptor_pools[1] = DescriptorPool.New(device, pool_sizes, own_set_count * set_count)

		for frame = 1, set_count do
			descriptor_sets[frame] = {}

			for i, layout in ipairs(set_layouts) do
				if layout == bindless_state.layout then
					descriptor_sets[frame][i] = bindless_state.set
				else
					descriptor_sets[frame][i] = descriptor_pools[1]:AllocateDescriptorSet(layout)
				end
			end
		end
	end

	local self = RayTracingPipeline:CreateObject{
		vulkan_instance = {device = device},
		config = config,
		internal = internal,
		pipeline_layout = internal.pipeline_layout,
		descriptor_pools = descriptor_pools,
		descriptor_sets = descriptor_sets,
		descriptor_set_layouts = set_layouts,
		descriptor_binding_counts = binding_counts,
	}

	if config.bindless then
		self:InitializeTextureRegistry(device)
		self.sampler_config = common.normalize_pipeline_sampler_config(nil)
	end

	return self
end

common.bind_descriptor_set_methods(RayTracingPipeline)

function RayTracingPipeline:GetDescriptorSetCount()
	return self.descriptor_sets and #self.descriptor_sets or 0
end

function RayTracingPipeline:DispatchRays(cmd, width, height, depth, frame_index)
	frame_index = frame_index or 1
	self.internal:DispatchRays(cmd, width, height, depth, self.descriptor_sets[frame_index])
end

function RayTracingPipeline:OnRemove()
	self.internal:OnRemove()

	for _, pool in ipairs(self.descriptor_pools) do
		if pool then pool:Remove() end
	end
end

return RayTracingPipeline:Register()
