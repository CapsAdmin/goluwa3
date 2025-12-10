local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local QueryPool = {}
QueryPool.__index = QueryPool

function QueryPool.New(device, query_type, query_count)
	local ptr = vulkan.T.Box(vulkan.vk.VkQueryPool)()
	local createInfo = vulkan.vk.s.QueryPoolCreateInfo(
		{
			queryType = vulkan.vk.e.VkQueryType(query_type or "occlusion"),
			queryCount = query_count or 1,
			pipelineStatistics = 0,
			flags = 0,
		}
	)
	vulkan.assert(
		vulkan.lib.vkCreateQueryPool(device.ptr[0], createInfo, nil, ptr),
		"failed to create query pool"
	)
	return setmetatable({
		ptr = ptr,
		device = device,
		query_count = query_count or 1,
	}, QueryPool)
end

function QueryPool:__gc()
	vulkan.lib.vkDestroyQueryPool(self.device.ptr[0], self.ptr[0], nil)
end

function QueryPool:Reset(cmd, first_query, query_count)
	vulkan.lib.vkCmdResetQueryPool(cmd.ptr[0], self.ptr[0], first_query or 0, query_count or self.query_count)
end

function QueryPool:GetResults(first_query, query_count, data_size, flags)
	local results = ffi.new("uint64_t[?]", query_count or 1)
	local result = vulkan.lib.vkGetQueryPoolResults(
		self.device.ptr[0],
		self.ptr[0],
		first_query or 0,
		query_count or 1,
		data_size or ffi.sizeof("uint64_t") * (query_count or 1),
		results,
		ffi.sizeof("uint64_t"),
		flags or
			bit.bor(
				vulkan.vk.VkQueryResultFlagBits.VK_QUERY_RESULT_64_BIT,
				vulkan.vk.VkQueryResultFlagBits.VK_QUERY_RESULT_WAIT_BIT
			)
	)

	if result == 0 then return results end

	return nil
end

return QueryPool
