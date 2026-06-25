local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local ComputePipeline = objects.CreateTemplate("vulkan_compute_pipeline")
local VkPipelineBox = ffi.typeof("$[1]", vulkan.vk.VkPipeline)

function ComputePipeline.New(device, shaderModule, pipelineLayout)
	local info = vulkan.vk.s.PipelineShaderStageCreateInfo{
		stage = vulkan.vk.e.VkShaderStageFlagBits("compute"),
		module = shaderModule.ptr[0],
		pName = "main",
	}
	local computePipelineCreateInfo = vulkan.vk.s.ComputePipelineCreateInfo{
		stage = info,
		layout = pipelineLayout.ptr[0],
		basePipelineHandle = nil,
		basePipelineIndex = -1,
	}
	local ptr = VkPipelineBox()
	vulkan.assert(
		vulkan.lib.vkCreateComputePipelines(device.ptr[0], nil, 1, computePipelineCreateInfo, nil, ptr),
		"failed to create compute pipeline"
	)
	return ComputePipeline:CreateObject{device = device, ptr = ptr}
end

function ComputePipeline:OnRemove()
	if self.device:IsValid() then
		local device = self.device
		local device_ptr = device.ptr[0]
		local pipeline_ptr = self.ptr[0]
		self.ptr[0] = nil

		device:DeferRelease(function()
			vulkan.lib.vkDestroyPipeline(device_ptr, pipeline_ptr, nil)
		end)
	end
end

return ComputePipeline:Register()
