local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local DescriptorPool = {}
DescriptorPool.__index = DescriptorPool

function DescriptorPool.New(device, poolSizes, maxSets)
	-- poolSizes is an array of tables: {{type, count}, ...}
	local poolSizeArray = vulkan.T.Array(vulkan.vk.VkDescriptorPoolSize)(#poolSizes)

	for i, ps in ipairs(poolSizes) do
		poolSizeArray[i - 1].type = vulkan.enums.VK_DESCRIPTOR_TYPE_(ps.type)
		poolSizeArray[i - 1].descriptorCount = ps.count or 1
	end

	local poolInfo = vulkan.vk.VkDescriptorPoolCreateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO",
			flags = bit.bor(
				0,
				vulkan.vk.VkDescriptorPoolCreateFlagBits("VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT"),
				vulkan.vk.VkDescriptorPoolCreateFlagBits("VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT")
			),
			poolSizeCount = #poolSizes,
			pPoolSizes = poolSizeArray,
			maxSets = maxSets or 1,
		}
	)
	local ptr = vulkan.T.Box(vulkan.vk.VkDescriptorPool)()
	vulkan.assert(
		vulkan.lib.vkCreateDescriptorPool(device.ptr[0], poolInfo, nil, ptr),
		"failed to create descriptor pool"
	)
	return setmetatable({device = device, ptr = ptr, poolSizeArray = poolSizeArray}, DescriptorPool)
end

function DescriptorPool:__gc()
	vulkan.lib.vkDestroyDescriptorPool(self.device.ptr[0], self.ptr[0], nil)
end

function DescriptorPool:Reset()
	vulkan.assert(
		vulkan.lib.vkResetDescriptorPool(self.device.ptr[0], self.ptr[0], 0),
		"failed to reset descriptor pool"
	)
end

function DescriptorPool:AllocateDescriptorSet(layout)
	local allocInfo = vulkan.vk.VkDescriptorSetAllocateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO",
			descriptorPool = self.ptr[0],
			descriptorSetCount = 1,
			pSetLayouts = layout.ptr,
		}
	)
	local ptr = vulkan.T.Box(vulkan.vk.VkDescriptorSet)()
	vulkan.assert(
		vulkan.lib.vkAllocateDescriptorSets(self.device.ptr[0], allocInfo, ptr),
		"failed to allocate descriptor set"
	)
	return {ptr = ptr, device = self.device}
end

return DescriptorPool
