local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local PipelineLayout = {}
PipelineLayout.__index = PipelineLayout

-- used to pass data to shaders
function PipelineLayout.New(device, descriptorSetLayouts, pushConstantRanges)
	-- descriptorSetLayouts is an optional array of DescriptorSetLayout objects
	-- pushConstantRanges is an optional array of {stage, offset, size}
	local setLayoutArray = nil
	local setLayoutCount = 0

	if descriptorSetLayouts and #descriptorSetLayouts > 0 then
		setLayoutCount = #descriptorSetLayouts
		setLayoutArray = vulkan.T.Array(vulkan.vk.VkDescriptorSetLayout)(setLayoutCount)

		for i, layout in ipairs(descriptorSetLayouts) do
			setLayoutArray[i - 1] = layout.ptr[0]
		end
	end

	local pushConstantArray = nil
	local pushConstantCount = 0

	if pushConstantRanges and #pushConstantRanges > 0 then
		pushConstantCount = #pushConstantRanges
		pushConstantArray = vulkan.T.Array(vulkan.vk.VkPushConstantRange)(pushConstantCount)

		for i, range in ipairs(pushConstantRanges) do
			pushConstantArray[i - 1] = {
				stageFlags = vulkan.vk.e.VkShaderStageFlagBits(range.stage),
				offset = range.offset,
				size = range.size,
			}
		end
	end

	local pipelineLayoutInfo = vulkan.vk.s.PipelineLayoutCreateInfo(
		{
			setLayoutCount = setLayoutCount,
			pSetLayouts = setLayoutArray,
			pushConstantRangeCount = pushConstantCount,
			pPushConstantRanges = pushConstantArray,
			flags = 0,
		}
	)
	local ptr = vulkan.T.Box(vulkan.vk.VkPipelineLayout)()
	vulkan.assert(
		vulkan.lib.vkCreatePipelineLayout(device.ptr[0], pipelineLayoutInfo, nil, ptr),
		"failed to create pipeline layout"
	)
	return setmetatable({device = device, ptr = ptr}, PipelineLayout)
end

function PipelineLayout:__gc()
	vulkan.lib.vkDestroyPipelineLayout(self.device.ptr[0], self.ptr[0], nil)
end

return PipelineLayout
