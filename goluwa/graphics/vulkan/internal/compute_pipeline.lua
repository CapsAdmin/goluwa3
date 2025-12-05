local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local ComputePipeline = {}
ComputePipeline.__index = ComputePipeline

function ComputePipeline.New(device, shaderModule, pipelineLayout)
	local info = vulkan.vk.s.PipelineShaderStageCreateInfo(
		{
			stage = compute,
			module = shaderModule.ptr[0],
			pName = "main",
		}
	)
	local computePipelineCreateInfo = vulkan.vk.s.ComputePipelineCreateInfo(
		{
			stage = info,
			layout = pipelineLayout.ptr[0],
			basePipelineHandle = nil,
			basePipelineIndex = -1,
		}
	)
	local ptr = vulkan.T.Box(vulkan.vk.VkPipeline)()
	vulkan.assert(
		vulkan.lib.vkCreateComputePipelines(device.ptr[0], nil, 1, computePipelineCreateInfo, nil, ptr),
		"failed to create compute pipeline"
	)
	return setmetatable({device = device, ptr = ptr}, ComputePipeline)
end

function ComputePipeline:__gc()
	vulkan.lib.vkDestroyPipeline(self.device.ptr[0], self.ptr[0], nil)
end

return ComputePipeline
