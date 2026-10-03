local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local Buffer = import("goluwa/render/vulkan/internal/buffer.lua")
local OcclusionQuery = objects.CreateTemplate("vulkan_occlusion_query")
local VkQueryPoolBox = ffi.typeof("$[1]", vulkan.vk.VkQueryPool)

function OcclusionQuery.New(config)
	local device = config.device
	local instance = config.instance
	local query_pool_ptr = VkQueryPoolBox()
	vulkan.assert(
		vulkan.lib.vkCreateQueryPool(
			device.ptr[0],
			vulkan.vk.s.QueryPoolCreateInfo{
				flags = 0,
				queryType = "occlusion",
				queryCount = 1,
				pipelineStatistics = 0,
			},
			nil,
			query_pool_ptr
		),
		"failed to create occlusion query pool"
	)
	local conditional_buffer = Buffer.New{
		device = device,
		size = 4,
		usage = {"conditional_rendering_ext", "transfer_dst"},
		properties = {"host_visible", "host_coherent"},
		name = "render occlusion conditional buffer",
	}
	local initial_value = ffi.new("uint32_t[1]", 1)
	conditional_buffer:CopyData(initial_value, 4)
	local self = OcclusionQuery:CreateObject{
		query_pool = query_pool_ptr,
		conditional_buffer = conditional_buffer,
		device = device,
		instance = instance,
		needs_reset = true,
	}
	return self
end

function OcclusionQuery:OnRemove()
	if self.device:IsValid() then
		self.device:WaitIdle()

		if
			self.query_pool and
			self.query_pool[0] ~= nil and
			tonumber(ffi.cast("uint64_t", self.query_pool[0])) ~= 0
		then
			vulkan.lib.vkDestroyQueryPool(self.device.ptr[0], self.query_pool[0], nil)
			self.query_pool[0] = nil
		end
	end
end

function OcclusionQuery:Delete()
	self:Remove()
end

function OcclusionQuery:ResetQuery(cmd)
	if self.needs_reset then
		vulkan.lib.vkCmdResetQueryPool(cmd.ptr[0], self.query_pool[0], 0, 1)
		self.needs_reset = false
		self.query_executed = false
	end
end

function OcclusionQuery:BeginQuery(cmd)
	vulkan.lib.vkCmdBeginQuery(cmd.ptr[0], self.query_pool[0], 0, 0)
end

function OcclusionQuery:EndQuery(cmd)
	vulkan.lib.vkCmdEndQuery(cmd.ptr[0], self.query_pool[0], 0)
	self.query_executed = true
end

function OcclusionQuery:CopyQueryResults(cmd)
	if not self.query_executed then return end

	vulkan.lib.vkCmdCopyQueryPoolResults(
		cmd.ptr[0],
		self.query_pool[0],
		0,
		1,
		self.conditional_buffer.ptr[0],
		0,
		4,
		vulkan.vk.VkQueryResultFlagBits.VK_QUERY_RESULT_WAIT_BIT
	)
	self.needs_reset = true
	self.query_executed = false
end

function OcclusionQuery:IsVisible()
	local result_ptr = ffi.cast("uint32_t *", self.conditional_buffer:Map())
	return tonumber(result_ptr[0]) ~= 0
end

function OcclusionQuery:BeginConditional(cmd)
	if not self.device.vkCmdBeginConditionalRenderingEXT then
		local success, func = pcall(
			vulkan.vk.GetExtension,
			vulkan.lib,
			self.instance.ptr[0],
			"vkCmdBeginConditionalRenderingEXT"
		)

		if not success then return false end

		self.device.vkCmdBeginConditionalRenderingEXT = func
		local success2, func2 = pcall(
			vulkan.vk.GetExtension,
			vulkan.lib,
			self.instance.ptr[0],
			"vkCmdEndConditionalRenderingEXT"
		)

		if not success2 then return false end

		self.device.vkCmdEndConditionalRenderingEXT = func2
	end

	local begin_info = vulkan.vk.s.ConditionalRenderingBeginInfoEXT{
		buffer = self.conditional_buffer.ptr[0],
		offset = 0,
		flags = 0,
	}
	self.device.vkCmdBeginConditionalRenderingEXT(cmd.ptr[0], begin_info)
	return true
end

function OcclusionQuery:EndConditional(cmd)
	if not self.device.vkCmdEndConditionalRenderingEXT then return end

	self.device.vkCmdEndConditionalRenderingEXT(cmd.ptr[0])
end

return OcclusionQuery:Register()
