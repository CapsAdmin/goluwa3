local objects = import("goluwa/objects/objects.lua")
local DescriptorPool = import("goluwa/render/vulkan/internal/descriptor_pool.lua")
local InternalRayTracingPipeline = import("goluwa/render/vulkan/internal/ray_tracing_pipeline.lua")
local common = import("goluwa/render/vulkan/pipeline_common.lua")
local render = import("goluwa/render/render.lua")
local event = import("goluwa/event.lua")
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

local function bindless_bindings()
	local capacities = render.GetBindlessDescriptorCapacities()
	return {
		{
			binding_index = 0,
			type = "combined_image_sampler",
			stageFlags = "all",
			count = capacities.textures,
		},
		{
			binding_index = 1,
			type = "combined_image_sampler",
			stageFlags = "all",
			count = capacities.cubemaps,
		},
		{
			binding_index = 2,
			type = "sampled_image",
			stageFlags = "all",
			count = capacities.views,
		},
		{
			binding_index = 3,
			type = "sampler",
			stageFlags = "all",
			count = capacities.samplers,
		},
	}
end

function RayTracingPipeline.New(device, config)
	local set_bindings = config.descriptor_sets

	if config.bindless then set_bindings = {set_bindings[1], bindless_bindings()} end

	local internal = InternalRayTracingPipeline.New(
		device,
		{
			stages = config.stages,
			descriptor_sets = set_bindings,
			max_recursion_depth = config.max_recursion_depth,
			max_ray_payload_size = config.max_ray_payload_size,
			push_constants_size = config.push_constants_size,
		}
	)
	local set_count = config.DescriptorSetCount or 1
	local pool_sizes = pool_sizes_from_bindings(set_bindings)
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

	if #set_layouts > 0 then
		for frame = 1, set_count do
			descriptor_pools[frame] = DescriptorPool.New(device, pool_sizes, #set_layouts)
			descriptor_sets[frame] = {}

			for i, layout in ipairs(set_layouts) do
				descriptor_sets[frame][i] = descriptor_pools[frame]:AllocateDescriptorSet(layout)
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
		self:InitializeTextureRegistry()
		self.max_textures = binding_counts[1][0]
		self.max_cubemaps = binding_counts[1][1]
		self.max_texture_views = binding_counts[1][2]
		self.max_texture_samplers = binding_counts[1][3]
		self.sampler_config = common.normalize_pipeline_sampler_config(nil)

		event.AddListener("TextureRemoved", self, function(removed_tex)
			if not render.GetDevice():IsValid() then return end

			if render.shutting_down then return end

			self:ReleaseTextureIndex(removed_tex, 1)
			self:ReleaseViewIndex(removed_tex)
		end)

		event.AddListener("TextureViewChanged", self, function(tex)
			self:RefreshTextureView(tex)
		end)
	end

	return self
end

common.bind_descriptor_set_methods(RayTracingPipeline)

function RayTracingPipeline:GetDescriptorSetCount()
	return self.descriptor_sets and #self.descriptor_sets or 0
end

function RayTracingPipeline:DispatchRays(cmd, width, height, depth, frame_index)
	frame_index = frame_index or 1
	local dirty = self.bindless_descriptor_sets_dirty

	if dirty and dirty[frame_index] then
		self:UpdateDescriptorSetArray(frame_index, 0, 1, self.texture_array)
		self:UpdateDescriptorSetArray(frame_index, 1, 1, self.cubemap_array)
		self:UpdateSampledImageDescriptorSetArray(frame_index, 2, 1, self.view_array)
		self:UpdateSamplerDescriptorSetArray(frame_index, 3, 1, self.sampler_array)
		dirty[frame_index] = nil
	end

	self.internal:DispatchRays(cmd, width, height, depth, self.descriptor_sets[frame_index])
end

function RayTracingPipeline:OnRemove()
	local event = import("goluwa/event.lua")
	event.RemoveListener("TextureRemoved", self)
	event.RemoveListener("TextureViewChanged", self)
	self.internal:OnRemove()

	for _, pool in ipairs(self.descriptor_pools) do
		if pool then pool:Remove() end
	end
end

return RayTracingPipeline:Register()
