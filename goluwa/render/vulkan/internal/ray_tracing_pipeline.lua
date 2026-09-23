local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local render = import("goluwa/render/render.lua")
local ShaderModule = import("goluwa/render/vulkan/internal/shader_module.lua")
local DescriptorSetLayout = import("goluwa/render/vulkan/internal/descriptor_set_layout.lua")
local PipelineLayout = import("goluwa/render/vulkan/internal/pipeline_layout.lua")
local RayTracingPipeline = objects.CreateTemplate("vulkan_ray_tracing_pipeline")
local VkPipelineBox = ffi.typeof("$[1]", vulkan.vk.VkPipeline)
local VkRayTracingShaderGroupCreateInfoArray = ffi.typeof("$[?]", vulkan.vk.VkRayTracingShaderGroupCreateInfoKHR)
local VkPipelineShaderStageCreateInfoArray = ffi.typeof("$[?]", vulkan.vk.VkPipelineShaderStageCreateInfo)

function RayTracingPipeline.New(device, config)
	local stage_count = #config.stages
	local shader_modules = {}
	local stage_modules = {}
	local stage_flags = {}
	local name_to_flag = {
		raygeneration = "raygen_khr",
		closesthit = "closest_hit_khr",
		miss = "miss_khr",
		anyhit = "anyhit_khr",
		intersection = "intersection_khr",
		callable = "callable_khr",
	}

	for i, stage in ipairs(config.stages) do
		local spirv_data, spirv_size

		if stage.spv then
			spirv_data, spirv_size = stage.spv, #stage.spv
		else
			local module = ShaderModule.New(device, stage.code, stage.name)
			spirv_data, spirv_size = module:Data()
			shader_modules[i] = module
		end

		assert(spirv_size > 0, "ray tracing stage " .. stage.name .. " has no SPIR-V code")
		stage_modules[i] = ShaderModule.FromSPIRV(device, spirv_data, spirv_size)
		stage_flags[i] = name_to_flag[stage.name] or "raygen_khr"
	end

	local groups = VkRayTracingShaderGroupCreateInfoArray(stage_count)

	for i, stage in ipairs(config.stages) do
		local type_name
		local general_shader = i - 1
		local closest_hit_shader = 0xFFFFFFFF

		if stage.name == "closesthit" then
			type_name = "triangles_hit_group_khr"
			general_shader = 0xFFFFFFFF
			closest_hit_shader = i - 1
		else
			type_name = "general_khr"
		end

		groups[i - 1] = vulkan.vk.s.RayTracingShaderGroupCreateInfoKHR{
			sType = "ray_tracing_shader_group_create_info_khr",
			pNext = nil,
			type = type_name,
			generalShader = general_shader,
			closestHitShader = closest_hit_shader,
			anyHitShader = 0xFFFFFFFF,
			intersectionShader = 0xFFFFFFFF,
			pShaderGroupCaptureReplayHandle = nil,
		}
	end

	local stages = VkPipelineShaderStageCreateInfoArray(stage_count)

	for i = 1, stage_count do
		stages[i - 1] = vulkan.vk.s.PipelineShaderStageCreateInfo{
			sType = "pipeline_shader_stage_create_info",
			pNext = nil,
			flags = 0,
			stage = stage_flags[i],
			module = stage_modules[i].ptr[0],
			pName = "main",
			pSpecializationInfo = nil,
		}
	end

	local pipeline_layout
	local layouts

	if config.descriptor_sets and #config.descriptor_sets > 0 then
		layouts = {}

		for set_index, bindings in ipairs(config.descriptor_sets) do
			layouts[set_index] = DescriptorSetLayout.New(device, bindings)
		end

		local push_constants = nil

		if config.push_constants_size then
			push_constants = {
				{
					stage = "ray_tracing",
					offset = 0,
					size = config.push_constants_size,
				},
			}
		end

		pipeline_layout = PipelineLayout.New(device, layouts, push_constants)
	end

	local create_info = vulkan.vk.s.RayTracingPipelineCreateInfoKHR{
		sType = "ray_tracing_pipeline_create_info_khr",
		pNext = nil,
		flags = 0,
		stageCount = stage_count,
		pStages = stages,
		groupCount = stage_count,
		pGroups = groups,
		maxPipelineRayRecursionDepth = config.max_recursion_depth or 1,
		maxPipelineRayPayloadSize = config.max_ray_payload_size or 64,
		pLibraryInfo = nil,
		pLibraryInterface = nil,
		pDynamicState = nil,
		layout = pipeline_layout and pipeline_layout.ptr[0] or nil,
		basePipelineHandle = nil,
		basePipelineIndex = -1,
	}
	local create_pipelines = device:GetExtension("vkCreateRayTracingPipelinesKHR")
	local ptr = VkPipelineBox()
	vulkan.assert(
		create_pipelines(device.ptr[0], nil, nil, 1, create_info, nil, ptr),
		"failed to create ray tracing pipeline"
	)
	local get_handle_size = device:TryGetExtension("vkGetRayTracingShaderGroupHandleSizeKHR")
	local handle_size = get_handle_size and get_handle_size(device.ptr[0]) or 32
	local group_count = stage_count
	local get_handles = device:GetExtension("vkGetRayTracingShaderGroupHandlesKHR")
	local handles = ffi.new("uint8_t[?]", handle_size * group_count)
	vulkan.assert(
		get_handles(device.ptr[0], ptr[0], 0, group_count, handle_size * group_count, handles),
		"failed to get ray tracing shader group handles"
	)
	local props = vulkan.vk.s.PhysicalDeviceRayTracingPipelinePropertiesKHR()
	props.sType = 1000347001
	props.pNext = nil
	local pd2 = vulkan.vk.s.PhysicalDeviceProperties2()
	pd2.sType = 1000059001
	pd2.pNext = props
	vulkan.lib.vkGetPhysicalDeviceProperties2(device.physical_device.ptr[0], pd2)
	local base_align = props.shaderGroupBaseAlignment
	local record_stride = (base_align + 63) & ~63
	local stage_index = {}

	for i, stage in ipairs(config.stages) do
		stage_index[stage.name] = i
	end

	local total_size = record_stride * stage_count
	local sbt = ffi.new("uint8_t[?]", total_size)
	local sbt_ptr = ffi.cast("uint8_t*", sbt)
	local handles_ptr = ffi.cast("uint8_t*", handles)

	for i = 1, group_count do
		ffi.copy(
			sbt_ptr + (i - 1) * record_stride,
			handles_ptr + (i - 1) * handle_size,
			handle_size
		)
	end

	local records_buffer = render.CreateBuffer{
		byte_size = total_size,
		buffer_usage = {"shader_device_address", "shader_binding_table_khr", "transfer_src"},
		memory_property = {"host_visible", "device_local"},
		label = "ray_tracing_shader_binding_table",
		data = sbt,
	}
	local self = RayTracingPipeline:CreateObject{
		device = device,
		pipeline = ptr[0],
		records_buffer = records_buffer,
		record_stride = record_stride,
		shader_modules = shader_modules,
		pipeline_layout = pipeline_layout,
		set_layouts = layouts,
		stage_count = stage_count,
		stage_index = stage_index,
		trace_rays = device:TryGetExtension("vkCmdTraceRaysKHR"),
	}
	return self
end

local function shader_record_region(self, name)
	local index = self.stage_index[name]

	if not index then
		return {
			deviceAddress = 0,
			stride = 0,
			size = 0,
		}
	end

	local base = self.records_buffer:GetDeviceAddress() + (index - 1) * self.record_stride
	return {
		deviceAddress = base,
		stride = self.record_stride,
		size = self.record_stride,
	}
end

function RayTracingPipeline:DispatchRays(cmd, width, height, depth, descriptor_set)
	vulkan.lib.vkCmdBindPipeline(cmd.ptr[0], vulkan.vk.e.VkPipelineBindPoint("ray_tracing_khr"), self.pipeline)
	cmd:BindDescriptorSets("ray_tracing_khr", self.pipeline_layout, {descriptor_set}, nil, 0)
	local region_t = ffi.typeof("$[1]", vulkan.vk.VkStridedDeviceAddressRegionKHR)
	local rgs = region_t()
	local chs = region_t()
	local miss = region_t()
	local call = region_t()
	local r = shader_record_region(self, "raygeneration")
	local c = shader_record_region(self, "closesthit")
	local m = shader_record_region(self, "miss")
	rgs[0].deviceAddress = r.deviceAddress
	rgs[0].stride = r.stride
	rgs[0].size = r.size
	chs[0].deviceAddress = c.deviceAddress
	chs[0].stride = c.stride
	chs[0].size = c.size
	miss[0].deviceAddress = m.deviceAddress
	miss[0].stride = m.stride
	miss[0].size = m.size
	call[0].deviceAddress = 0
	call[0].stride = 0
	call[0].size = 0
	self.trace_rays(cmd.ptr[0], rgs, miss, chs, call, width, height, depth)
end

function RayTracingPipeline:OnRemove()
	if self.pipeline and self.device:IsValid() then
		local device = self.device
		local pipeline = self.pipeline
		self.pipeline = nil

		device:DeferRelease(function()
			vulkan.lib.vkDestroyPipeline(device.ptr[0], pipeline, nil)
		end)
	end

	for _, module in ipairs(self.shader_modules) do
		if module then module:Remove() end
	end

	if self.pipeline_layout then self.pipeline_layout:Remove() end

	if self.records_buffer then self.records_buffer:Remove() end
end

return RayTracingPipeline:Register()
