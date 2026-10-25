local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local ComputePipeline = objects.CreateTemplate("vulkan_compute_pipeline")
local VkPipelineBox = ffi.typeof("$[1]", vulkan.vk.VkPipeline)
local VkComputePipelineCreateInfoBox = ffi.typeof("$[1]", vulkan.vk.VkComputePipelineCreateInfo)

function ComputePipeline.New(device, shaderModule, pipelineLayout, name)
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
	local info_box = VkComputePipelineCreateInfoBox()
	info_box[0] = computePipelineCreateInfo
	local job = device.pipeline_cache:RunCreate(vulkan.lib.vkCreateComputePipelines, info_box, ptr)
	return ComputePipeline:CreateObject{
		device = device,
		ptr = ptr,
		name = name,
		job = job,
		keep = {info, computePipelineCreateInfo, info_box},
	}
end

function ComputePipeline:Wait()
	local job = self.job

	if job then
		self.job = nil
		self.device.pipeline_cache:WaitForJob(job, "compute", self.name)
		self.keep = nil
	end
end

function ComputePipeline:OnRemove()
	pcall(self.Wait, self)

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
