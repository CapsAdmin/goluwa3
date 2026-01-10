local ffi = require("ffi")
local prototype = require("prototype")
local vulkan = require("render.vulkan.internal.vulkan")
local Buffer = require("render.vulkan.internal.buffer")
local OcclusionQuery = prototype.CreateTemplate("vulkan", "occlusion_query")

function OcclusionQuery.New(config)
	local device = config.device
	local instance = config.instance
	-- Create a query pool for occlusion queries
	local query_pool_ptr = vulkan.T.Box(vulkan.vk.VkQueryPool)()
	vulkan.assert(
		vulkan.lib.vkCreateQueryPool(
			device.ptr[0],
			vulkan.vk.s.QueryPoolCreateInfo(
				{
					flags = 0,
					queryType = "occlusion",
					queryCount = 1,
					pipelineStatistics = 0,
				}
			),
			nil,
			query_pool_ptr
		),
		"failed to create occlusion query pool"
	)
	-- Create a buffer to hold the occlusion query result for conditional rendering
	-- Use host_visible so we can initialize it directly without a copy command
	local conditional_buffer = Buffer.New(
		{
			device = device,
			size = 4,
			usage = {"conditional_rendering_ext", "transfer_dst"},
			properties = {"host_visible", "host_coherent"},
		}
	)
	-- Initialize buffer to 1 (visible) so objects start visible
	local initial_value = ffi.new("uint32_t[1]", 1)
	conditional_buffer:CopyData(initial_value, 4)
	local self = OcclusionQuery:CreateObject(
		{
			query_pool = query_pool_ptr,
			conditional_buffer = conditional_buffer,
			device = device,
			instance = instance,
			needs_reset = true, -- Track if query needs reset before use
		}
	)
	return self
end

function OcclusionQuery:OnRemove()
	if self.device:IsValid() then
		self.device:WaitIdle()
		vulkan.lib.vkDestroyQueryPool(self.device.ptr[0], self.query_pool[0], nil)
	end
end

function OcclusionQuery:Delete()
	if self.query_pool and self.query_pool[0] then
		vulkan.lib.vkDestroyQueryPool(self.device.ptr[0], self.query_pool[0], nil)
		self.query_pool = nil
	end

	if self.conditional_buffer then self.conditional_buffer = nil end
end

-- Reset query pool (must be called outside render pass)
function OcclusionQuery:ResetQuery(cmd)
	if self.needs_reset then
		vulkan.lib.vkCmdResetQueryPool(cmd.ptr[0], self.query_pool[0], 0, 1)
		self.needs_reset = false
		self.query_executed = false -- Mark query as not executed yet
	end
end

-- Begin occlusion query
function OcclusionQuery:BeginQuery(cmd)
	-- Begin occlusion query
	vulkan.lib.vkCmdBeginQuery(cmd.ptr[0], self.query_pool[0], 0, -- query index
	0 -- flags (0 = non-precise query, which is faster)
	)
end

-- End occlusion query
function OcclusionQuery:EndQuery(cmd)
	vulkan.lib.vkCmdEndQuery(cmd.ptr[0], self.query_pool[0], 0)
	self.query_executed = true -- Mark that query was executed this frame
end

-- Copy query results to conditional buffer
function OcclusionQuery:CopyQueryResults(cmd)
	-- Only copy if query was executed this frame
	if not self.query_executed then return end

	-- Copy query results to the conditional buffer
	vulkan.lib.vkCmdCopyQueryPoolResults(
		cmd.ptr[0],
		self.query_pool[0],
		0, -- first query
		1, -- query count
		self.conditional_buffer.ptr[0],
		0, -- dst offset
		4, -- stride (4 bytes per result)
		vulkan.vk.VkQueryResultFlagBits.VK_QUERY_RESULT_WAIT_BIT -- Wait for results to be available
	)
	-- Mark query as needing reset for next frame
	self.needs_reset = true
	self.query_executed = false
end

-- Begin conditional rendering block
-- Drawing commands between Begin and End will only execute if the buffer contains non-zero
function OcclusionQuery:BeginConditional(cmd)
	-- Get the extension function (cached on device)
	if not self.device.vkCmdBeginConditionalRenderingEXT then
		self.device.vkCmdBeginConditionalRenderingEXT = vulkan.vk.GetExtension(vulkan.lib, self.instance.ptr[0], "vkCmdBeginConditionalRenderingEXT")
		self.device.vkCmdEndConditionalRenderingEXT = vulkan.vk.GetExtension(vulkan.lib, self.instance.ptr[0], "vkCmdEndConditionalRenderingEXT")
	end

	local begin_info = vulkan.vk.s.ConditionalRenderingBeginInfoEXT({
		buffer = self.conditional_buffer.ptr[0],
		offset = 0,
		flags = 0,
	})
	self.device.vkCmdBeginConditionalRenderingEXT(cmd.ptr[0], begin_info)
	return true
end

-- End conditional rendering block
function OcclusionQuery:EndConditional(cmd)
	self.device.vkCmdEndConditionalRenderingEXT(cmd.ptr[0])
end

return OcclusionQuery:Register()
