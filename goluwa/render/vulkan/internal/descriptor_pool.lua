local ffi = require("ffi")
local prototype = require("prototype")
local vulkan = require("render.vulkan.internal.vulkan")
local DescriptorPool = prototype.CreateTemplate("vulkan_descriptor_pool")

function DescriptorPool.New(device, poolSizes, maxSets)
	-- poolSizes is an array of tables: {{type, count}, ...}
	local poolSizeArray = vulkan.T.Array(vulkan.vk.VkDescriptorPoolSize)(#poolSizes)

	for i, ps in ipairs(poolSizes) do
		poolSizeArray[i - 1].type = vulkan.vk.e.VkDescriptorType(ps.type)
		poolSizeArray[i - 1].descriptorCount = ps.count or 1
	end

	local poolInfo = vulkan.vk.s.DescriptorPoolCreateInfo(
		{
			flags = {"free_descriptor_set", "update_after_bind"},
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
	return DescriptorPool:CreateObject({device = device, ptr = ptr, poolSizeArray = poolSizeArray})
end

function DescriptorPool:OnRemove()
	if self.device:IsValid() then
		self.device:WaitIdle()
		vulkan.lib.vkDestroyDescriptorPool(self.device.ptr[0], self.ptr[0], nil)
	end
end

function DescriptorPool:Reset()
	vulkan.assert(
		vulkan.lib.vkResetDescriptorPool(self.device.ptr[0], self.ptr[0], 0),
		"failed to reset descriptor pool"
	)
end

function DescriptorPool:AllocateDescriptorSet(layout)
	local allocInfo = vulkan.vk.s.DescriptorSetAllocateInfo(
		{
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

return DescriptorPool:Register()
