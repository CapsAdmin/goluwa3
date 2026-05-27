local ffi = require("ffi")
local prototype = import("goluwa/prototype.lua")
local ShaderModule = import("goluwa/render/vulkan/internal/shader_module.lua")
local DescriptorSetLayout = import("goluwa/render/vulkan/internal/descriptor_set_layout.lua")
local PipelineLayout = import("goluwa/render/vulkan/internal/pipeline_layout.lua")
local ComputePipelineInternal = import("goluwa/render/vulkan/internal/compute_pipeline.lua")
local DescriptorPool = import("goluwa/render/vulkan/internal/descriptor_pool.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local ComputePipeline = prototype.CreateTemplate("render_compute_pipeline")

local function get_shader_stage_bits_u32(stage)
	if type(stage) == "string" then
		return tonumber(ffi.cast("uint32_t", vulkan.vk.e.VkShaderStageFlagBits(stage)))
	end

	return tonumber(ffi.cast("uint32_t", stage))
end

local function normalize_compat_config(config)
	if config.shader_stages then return config end

	local descriptor_sets = {}

	if config.descriptor_layout then
		for _, ds in ipairs(config.descriptor_layout) do
			descriptor_sets[#descriptor_sets + 1] = {
				type = ds.type,
				binding_index = ds.binding_index,
				count = ds.count,
				set_index = ds.set_index or 0,
			}
		end
	end

	local max_push_size = 0

	for _, range in ipairs(config.push_constant_ranges or {}) do
		max_push_size = math.max(max_push_size, (range.offset or 0) + (range.size or 0))
	end

	return {
		DescriptorSetCount = config.DescriptorSetCount or config.descriptor_set_count,
		LocalSize = config.LocalSize or config.local_size or config.workgroup_size,
		pool_sizes = config.pool_sizes,
		descriptor_pool = config.descriptor_pool,
		shader_stages = {
			{
				type = "compute",
				code = assert(config.shader, "ComputePipeline.New: shader is required"),
				descriptor_sets = descriptor_sets,
				push_constants = max_push_size > 0 and {
					offset = 0,
					size = max_push_size,
				} or nil,
			},
		},
	}
end

local function build_descriptor_layouts(config)
	local layout_maps = {}
	local pool_size_map = {}
	local descriptor_binding_counts = {}
	local uniform_buffers = {}
	local all_stage_bits = 0
	local max_push_end = 0
	local has_push_constants = false

	for _, stage in ipairs(config.shader_stages) do
		if stage.type ~= "compute" then
			error("ComputePipeline.New: only compute shader stages are supported", 3)
		end

		local stage_bits = get_shader_stage_bits_u32(stage.type)
		all_stage_bits = bit.bor(all_stage_bits, stage_bits)

		for _, ds in ipairs(stage.descriptor_sets or {}) do
			local set_index = ds.set_index or 0
			local binding_index = assert(ds.binding_index, "ComputePipeline.New: descriptor binding_index is required")
			layout_maps[set_index] = layout_maps[set_index] or {}
			local layout_map = layout_maps[set_index]

			if layout_map[binding_index] then
				layout_map[binding_index].stageFlags = bit.bor(layout_map[binding_index].stageFlags, stage_bits)
			else
				layout_map[binding_index] = {
					binding_index = binding_index,
					type = ds.type,
					stageFlags = stage_bits,
					count = ds.count or 1,
				}
				pool_size_map[ds.type] = (pool_size_map[ds.type] or 0) + (ds.count or 1)
			end

			descriptor_binding_counts[set_index] = descriptor_binding_counts[set_index] or {}
			descriptor_binding_counts[set_index][binding_index] = layout_map[binding_index].count or 1

			if ds.type == "uniform_buffer" or ds.type == "uniform_buffer_dynamic" then
				uniform_buffers[binding_index] = ds.args and ds.args[1] or nil
			end
		end

		if stage.push_constants then
			has_push_constants = true
			local offset = stage.push_constants.offset or 0
			local size = assert(stage.push_constants.size, "ComputePipeline.New: push constants size is required")
			max_push_end = math.max(max_push_end, offset + size)
		end
	end

	local push_constant_ranges = {}

	if has_push_constants then
		push_constant_ranges[1] = {
			stage = all_stage_bits,
			offset = 0,
			size = max_push_end,
		}
	end

	local descriptor_set_layouts = {}
	local max_set_index = 0

	for set_index in pairs(layout_maps) do
		max_set_index = math.max(max_set_index, set_index)
	end

	for set_index = 0, max_set_index do
		local layout_map = layout_maps[set_index] or {}
		local layout = {}

		for _, entry in pairs(layout_map) do
			layout[#layout + 1] = entry
		end

		table.sort(layout, function(a, b)
			return a.binding_index < b.binding_index
		end)

		descriptor_set_layouts[set_index + 1] = DescriptorSetLayout.New(config.vulkan_instance.device, layout)
	end

	local pool_sizes = {}

	for descriptor_type, count in pairs(pool_size_map) do
		pool_sizes[#pool_sizes + 1] = {
			type = descriptor_type,
			count = count,
		}
	end

	return {
		descriptor_set_layouts = descriptor_set_layouts,
		pool_sizes = pool_sizes,
		descriptor_binding_counts = descriptor_binding_counts,
		uniform_buffers = uniform_buffers,
		push_constant_ranges = push_constant_ranges,
	}
end

function ComputePipeline.New(vulkan_instance, raw_config)
	local config = normalize_compat_config(raw_config)
	config.vulkan_instance = vulkan_instance
	local self = ComputePipeline:CreateObject{
		vulkan_instance = vulkan_instance,
		config = config,
	}
	local stage = assert(
		config.shader_stages and config.shader_stages[1],
		"ComputePipeline.New: shader_stages[1] is required"
	)
	local shader = ShaderModule.New(
		vulkan_instance.device,
		assert(stage.code, "ComputePipeline.New: compute shader code is required"),
		"compute"
	)
	local descriptor_info = build_descriptor_layouts(config)

	if #descriptor_info.push_constant_ranges > 0 then
		local device_properties = vulkan_instance.physical_device:GetProperties()
		local max_push_constants_size = device_properties.limits.maxPushConstantsSize
		local range = descriptor_info.push_constant_ranges[1]

		if range.size > max_push_constants_size then
			error(
				string.format(
					"ComputePipeline.New: push constants size %d exceeds device limit %d",
					range.size,
					max_push_constants_size
				),
				3
			)
		end
	end

	local pipeline_layout = PipelineLayout.New(
		vulkan_instance.device,
		descriptor_info.descriptor_set_layouts,
		descriptor_info.push_constant_ranges
	)
	local pipeline = ComputePipelineInternal.New(vulkan_instance.device, shader, pipeline_layout)
	local descriptor_set_count = config.DescriptorSetCount or 1
	local pool_sizes = config.pool_sizes or config.descriptor_pool or descriptor_info.pool_sizes
	local descriptor_pools = {}
	local descriptor_sets = {}

	if #descriptor_info.descriptor_set_layouts > 0 then
		for frame = 1, descriptor_set_count do
			descriptor_pools[frame] = DescriptorPool.New(vulkan_instance.device, pool_sizes, #descriptor_info.descriptor_set_layouts)
			local frame_sets = {}

			for i, layout in ipairs(descriptor_info.descriptor_set_layouts) do
				frame_sets[i] = descriptor_pools[frame]:AllocateDescriptorSet(layout)
			end

			descriptor_sets[frame] = frame_sets
		end
	end

	local local_size = config.LocalSize

	if type(local_size) == "number" then
		local_size = {x = local_size, y = local_size, z = 1}
	elseif type(local_size) ~= "table" then
		local_size = {x = 8, y = 8, z = 1}
	else
		local_size = {
			x = local_size.x or local_size[1] or 8,
			y = local_size.y or local_size[2] or 8,
			z = local_size.z or local_size[3] or 1,
		}
	end

	self.shader = shader
	self.pipeline = pipeline
	self.pipeline_layout = pipeline_layout
	self.descriptor_set_layouts = descriptor_info.descriptor_set_layouts
	self.descriptor_binding_counts = descriptor_info.descriptor_binding_counts
	self.descriptor_pools = descriptor_pools
	self.descriptor_sets = descriptor_sets
	self.push_constant_ranges = descriptor_info.push_constant_ranges
	self.uniform_buffers = descriptor_info.uniform_buffers
	self.local_size = local_size
	return self
end

function ComputePipeline:GetDescriptorSetCount()
	return self.descriptor_sets and #self.descriptor_sets or 0
end

function ComputePipeline:GetUniformBuffer(binding_index)
	local ub = self.uniform_buffers[binding_index]

	if not ub then
		error("Invalid uniform buffer binding index: " .. tostring(binding_index), 2)
	end

	return ub
end

function ComputePipeline:UpdateDescriptorSet(type, index, binding_index, set_index, ...)
	if _G.type(set_index) ~= "number" then
		return self:UpdateDescriptorSet(type, index, binding_index, 0, set_index, ...)
	end

	self.vulkan_instance.device:UpdateDescriptorSet(type, self.descriptor_sets[index][set_index + 1], binding_index, ...)
end

function ComputePipeline:Bind(cmd, frame_index, dynamic_offsets)
	frame_index = frame_index or 1
	cmd:BindPipeline(self.pipeline, "compute")

	if self.descriptor_sets and #self.descriptor_sets > 0 then
		local sets = self.descriptor_sets[frame_index] or self.descriptor_sets[1]
		cmd:BindDescriptorSets("compute", self.pipeline_layout, sets, dynamic_offsets, 0)
	end
end

function ComputePipeline:PushConstants(cmd, stage, offset, data, data_size)
	local stage_bits

	if type(stage) == "table" then
		stage_bits = 0

		for _, stage_name in ipairs(stage) do
			stage_bits = bit.bor(stage_bits, get_shader_stage_bits_u32(stage_name))
		end
	else
		stage_bits = get_shader_stage_bits_u32(stage)
	end

	for _, range in ipairs(self.push_constant_ranges or {}) do
		if offset >= range.offset and offset < (range.offset + range.size) then
			stage_bits = bit.bor(stage_bits, range.stage)
		end
	end

	cmd:PushConstants(self.pipeline_layout, stage_bits, offset, data_size or ffi.sizeof(data), data)
end

function ComputePipeline:Dispatch(cmd, group_count_x, group_count_y, group_count_z, frame_index, dynamic_offsets)
	self:Bind(cmd, frame_index, dynamic_offsets)
	cmd:Dispatch(group_count_x or 1, group_count_y or 1, group_count_z or 1)
end

function ComputePipeline:DispatchForSize(cmd, width, height, depth, frame_index, dynamic_offsets)
	local ls = self.local_size
	local gx = math.ceil((width or 1) / math.max(ls.x, 1))
	local gy = math.ceil((height or 1) / math.max(ls.y, 1))
	local gz = math.ceil((depth or 1) / math.max(ls.z, 1))
	self:Dispatch(cmd, gx, gy, gz, frame_index, dynamic_offsets)
end

function ComputePipeline:OnRemove()
	if self.pipeline then self.pipeline:Remove() end

	if self.shader then self.shader:Remove() end

	if self.descriptor_pools then
		for _, pool in ipairs(self.descriptor_pools) do
			if pool then pool:Remove() end
		end
	end

	if self.descriptor_set_layouts then
		for _, layout in ipairs(self.descriptor_set_layouts) do
			if layout then layout:Remove() end
		end
	end

	if self.pipeline_layout then self.pipeline_layout:Remove() end
end

return ComputePipeline:Register()
