local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local DescriptorSetLayout = {}
DescriptorSetLayout.__index = DescriptorSetLayout

function DescriptorSetLayout.New(device, bindings)
	-- bindings is an array of tables: {{binding, type, stageFlags, count}, ...}
	local bindingArray = vulkan.T.Array(vulkan.vk.VkDescriptorSetLayoutBinding)(#bindings)
	local bindingFlagsArray = vulkan.T.Array(vulkan.vk.VkDescriptorBindingFlags)(#bindings)

	for i, b in ipairs(bindings) do
		bindingArray[i - 1].binding = assert(b.binding_index)
		bindingArray[i - 1].descriptorType = vulkan.vk.e.VkDescriptorType(b.type)
		bindingArray[i - 1].descriptorCount = b.count or 1
		bindingArray[i - 1].stageFlags = vulkan.vk.e.VkShaderStageFlagBits(b.stageFlags)
		bindingArray[i - 1].pImmutableSamplers = nil

		-- For bindless (large arrays), set flags for dynamic updates
		if (b.count or 1) > 1 then
			bindingFlagsArray[i - 1] = bit.bor(
				vulkan.vk.VkDescriptorBindingFlagBits("VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT"),
				vulkan.vk.VkDescriptorBindingFlagBits("VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT")
			)
		else
			bindingFlagsArray[i - 1] = 0
		end
	end -- Add binding flags for descriptor indexing
	local ptr = vulkan.T.Box(vulkan.vk.VkDescriptorSetLayout)()
	vulkan.assert(
		vulkan.lib.vkCreateDescriptorSetLayout(
			device.ptr[0],
			vulkan.vk.s.DescriptorSetLayoutCreateInfo(
				{
					flags = "update_after_bind_pool",
					pNext = vulkan.vk.s.DescriptorSetLayoutBindingFlagsCreateInfo(
						{
							pNext = nil,
							bindingCount = #bindings,
							pBindingFlags = bindingFlagsArray,
						}
					),
					bindingCount = #bindings,
					pBindings = bindingArray,
				}
			),
			nil,
			ptr
		),
		"failed to create descriptor set layout"
	)
	return setmetatable({ptr = ptr, device = device, bindingArray = bindingArray}, DescriptorSetLayout)
end

function DescriptorSetLayout:__gc()
	vulkan.lib.vkDestroyDescriptorSetLayout(self.device.ptr[0], self.ptr[0], nil)
end

return DescriptorSetLayout
