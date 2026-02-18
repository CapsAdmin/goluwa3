local ffi = require("ffi")
local prototype = require("prototype")
local vulkan = require("render.vulkan.internal.vulkan")
local DescriptorSetLayout = prototype.CreateTemplate("vulkan_descriptor_set_layout")

function DescriptorSetLayout.New(device, bindings)
	-- bindings is an array of tables: {{binding, type, stageFlags, count}, ...}
	local bindingArray = vulkan.T.Array(vulkan.vk.VkDescriptorSetLayoutBinding)(#bindings)
	local bindingFlagsArray = vulkan.T.Array(vulkan.vk.VkDescriptorBindingFlags)(#bindings)
	local has_dynamic_buffer = false

	for _, b in ipairs(bindings) do
		if b.type == "uniform_buffer_dynamic" or b.type == "storage_buffer_dynamic" then
			has_dynamic_buffer = true

			break
		end
	end

	for i, b in ipairs(bindings) do
		bindingArray[i - 1].binding = assert(b.binding_index)
		bindingArray[i - 1].descriptorType = vulkan.vk.e.VkDescriptorType(b.type)
		bindingArray[i - 1].descriptorCount = b.count or 1
		bindingArray[i - 1].stageFlags = vulkan.vk.e.VkShaderStageFlagBits(b.stageFlags)
		bindingArray[i - 1].pImmutableSamplers = nil

		-- For bindless (large arrays), set flags for dynamic updates
		-- But ONLY if there are no dynamic buffers, as required by Vulkan spec VUID-VkDescriptorSetLayoutCreateInfo-descriptorType-03001
		if (b.count or 1) > 1 and not has_dynamic_buffer then
			bindingFlagsArray[i - 1] = bit.bor(
				vulkan.vk.VkDescriptorBindingFlagBits.VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT,
				vulkan.vk.VkDescriptorBindingFlagBits.VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT
			)
		else
			bindingFlagsArray[i - 1] = 0
		end
	end -- Add binding flags for descriptor indexing
	local ptr = vulkan.T.Box(vulkan.vk.VkDescriptorSetLayout)()
	local flags = has_dynamic_buffer and 0 or {"update_after_bind_pool"}
	vulkan.assert(
		vulkan.lib.vkCreateDescriptorSetLayout(
			device.ptr[0],
			vulkan.vk.s.DescriptorSetLayoutCreateInfo(
				{
					flags = flags,
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
	return DescriptorSetLayout:CreateObject({ptr = ptr, device = device, bindingArray = bindingArray})
end

function DescriptorSetLayout:OnRemove()
	if self.device:IsValid() then
		self.device:WaitIdle()
		vulkan.lib.vkDestroyDescriptorSetLayout(self.device.ptr[0], self.ptr[0], nil)
	end
end

return DescriptorSetLayout:Register()
