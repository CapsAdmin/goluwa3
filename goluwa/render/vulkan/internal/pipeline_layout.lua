local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local PipelineLayout = objects.CreateTemplate("vulkan_pipeline_layout")
local VkDescriptorSetLayoutArray = ffi.typeof("$[?]", vulkan.vk.VkDescriptorSetLayout)
local VkPushConstantRangeArray = ffi.typeof("$[?]", vulkan.vk.VkPushConstantRange)
local VkPipelineLayoutBox = ffi.typeof("$[1]", vulkan.vk.VkPipelineLayout)

-- used to pass data to shaders
function PipelineLayout.New(device, descriptorSetLayouts, pushConstantRanges)
	-- descriptorSetLayouts is an optional array of DescriptorSetLayout objects
	-- pushConstantRanges is an optional array of {stage, offset, size}
	local setLayoutArray = nil
	local setLayoutCount = 0

	if descriptorSetLayouts and #descriptorSetLayouts > 0 then
		setLayoutCount = #descriptorSetLayouts
		setLayoutArray = VkDescriptorSetLayoutArray(setLayoutCount)

		for i, layout in ipairs(descriptorSetLayouts) do
			setLayoutArray[i - 1] = layout.ptr[0]
		end
	end

	local pushConstantArray = nil
	local pushConstantCount = 0

	if pushConstantRanges and #pushConstantRanges > 0 then
		pushConstantCount = #pushConstantRanges
		pushConstantArray = VkPushConstantRangeArray(pushConstantCount)

		for i, range in ipairs(pushConstantRanges) do
			pushConstantArray[i - 1] = {
				stageFlags = vulkan.vk.e.VkShaderStageFlagBits(range.stage),
				offset = range.offset,
				size = range.size,
			}
		end
	end

	local pipelineLayoutInfo = vulkan.vk.s.PipelineLayoutCreateInfo{
		setLayoutCount = setLayoutCount,
		pSetLayouts = setLayoutArray,
		pushConstantRangeCount = pushConstantCount,
		pPushConstantRanges = pushConstantArray,
		flags = 0,
	}
	local ptr = VkPipelineLayoutBox()
	vulkan.assert(
		vulkan.lib.vkCreatePipelineLayout(device.ptr[0], pipelineLayoutInfo, nil, ptr),
		"failed to create pipeline layout"
	)
	return PipelineLayout:CreateObject{device = device, ptr = ptr}
end

function PipelineLayout:OnRemove()
	if self.device:IsValid() then
		local device = self.device
		local device_ptr = device.ptr[0]
		local layout_ptr = self.ptr[0]
		self.ptr[0] = nil

		device:DeferRelease(function()
			vulkan.lib.vkDestroyPipelineLayout(device_ptr, layout_ptr, nil)
		end)
	end
end

return PipelineLayout:Register()
