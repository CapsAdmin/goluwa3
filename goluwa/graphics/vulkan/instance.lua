local ffi = require("ffi")
local VulkanInstance = {}
VulkanInstance.__index = VulkanInstance
-- Default configuration
local default_config = {
	-- Swapchain settings
	present_mode = "fifo", -- FIFO (vsync), IMMEDIATE (no vsync), MAILBOX (triple buffer)
	image_count = nil, -- nil = minImageCount + 1 (usually triple buffer)
	surface_format_index = 1, -- Which format from available formats to use
	composite_alpha = "opaque", -- OPAQUE, PRE_MULTIPLIED, POST_MULTIPLIED, INHERIT
	clipped = true, -- Clip pixels obscured by other windows
	image_usage = nil, -- nil = COLOR_ATTACHMENT | TRANSFER_DST, or provide custom flags
	-- Image acquisition
	acquire_timeout = ffi.cast("uint64_t", -1), -- Infinite timeout by default
	-- Presentation
	pre_transform = nil, -- nil = use currentTransform
}

function VulkanInstance.New(config)
	config = config or {}

	for k, v in pairs(default_config) do
		if config[k] == nil then config[k] = v end
	end

	local self = setmetatable({}, VulkanInstance)
	self.config = config
	self:Initialize(assert(self.config.surface_handle))
	return self
end

function VulkanInstance:Initialize(metal_surface)
	local layers = {}
	local extensions = {"VK_KHR_surface", "VK_EXT_metal_surface"}

	if os.getenv("VULKAN_SDK") then
		table.insert(layers, "VK_LAYER_KHRONOS_validation")
		table.insert(extensions, "VK_KHR_portability_enumeration")
	end

	-- Vulkan initialization
	local vulkan = require("bindings.vulkan")
	self.instance = vulkan.CreateInstance(extensions, layers)
	self.surface = self.instance:CreateMetalSurface(metal_surface)
	self.physical_device = self.instance:GetPhysicalDevices()[1]
	self.graphics_queue_family = self.physical_device:FindGraphicsQueueFamily(self.surface)
	self.device = self.physical_device:CreateDevice({"VK_KHR_swapchain"}, self.graphics_queue_family)
	self.command_pool = self.device:CreateCommandPool(self.graphics_queue_family)
	-- Get queue
	self.queue = self.device:GetQueue(self.graphics_queue_family)
	-- Create swapchain
	self:RecreateSwapchain()
	return self
end

function VulkanInstance:RecreateSwapchain()
	-- Wait for device to be idle (skip on initial creation)
	if self.swapchain then self:WaitForIdle() end

	-- Query surface capabilities and formats
	self.surface_capabilities = self.physical_device:GetSurfaceCapabilities(self.surface)
	local new_surface_formats = self.physical_device:GetSurfaceFormats(self.surface)

	-- Validate format index
	if self.config.surface_format_index > #new_surface_formats then
		error(
			"Invalid surface_format_index: " .. self.config.surface_format_index .. " (max: " .. (
					#new_surface_formats
				) .. ")"
		)
	end

	local selected_format = new_surface_formats[self.config.surface_format_index]

	if selected_format.format == "undefined" then
		error("selected surface format is undefined!")
	end

	self.surface_formats = new_surface_formats
	-- Build swapchain config
	local swapchain_config = {
		present_mode = self.config.present_mode,
		image_count = self.config.image_count or (self.surface_capabilities[0].minImageCount + 1),
		composite_alpha = self.config.composite_alpha,
		clipped = self.config.clipped,
		image_usage = self.config.image_usage,
		pre_transform = self.config.pre_transform,
	}
	-- Create new swapchain (pass old swapchain if it exists)
	self.swapchain = self.device:CreateSwapchain(
		self.surface,
		self.surface_formats[self.config.surface_format_index],
		self.surface_capabilities,
		swapchain_config,
		self.swapchain -- old swapchain for efficient recreation (nil on initial creation)
	)
	self.swapchain_images = self.swapchain:GetImages()
end

function VulkanInstance:TransitionImageLayout(image, old_layout, new_layout, src_stage, dst_stage)
	local cmd = self:GetCommandBuffer()
	src_stage = src_stage or "all_commands"
	dst_stage = dst_stage or "all_commands"
	local src_access = "none"
	local dst_access = "none"

	-- Determine access masks based on layouts
	if old_layout == "color_attachment_optimal" then
		src_access = "color_attachment_write"
	elseif old_layout == "shader_read_only_optimal" then
		src_access = "shader_read"
	end

	if new_layout == "color_attachment_optimal" then
		dst_access = "color_attachment_write"
	elseif new_layout == "shader_read_only_optimal" then
		dst_access = "shader_read"
	end

	cmd:PipelineBarrier(
		{
			srcStage = src_stage,
			dstStage = dst_stage,
			imageBarriers = {
				{
					image = image,
					srcAccessMask = src_access,
					dstAccessMask = dst_access,
					oldLayout = old_layout,
					newLayout = new_layout,
				},
			},
		}
	)
end

function VulkanInstance:GetExtent()
	return self.surface_capabilities[0].currentExtent
end

function VulkanInstance:WaitForIdle()
	self.device:WaitIdle()
end

function VulkanInstance:CreateBuffer(config)
	local byte_size
	local data = config.data

	if data then
		if type(data) == "table" then
			data = ffi.new((config.data_type or "float") .. "[" .. (#data) .. "]", data)
			byte_size = ffi.sizeof(data)
		else
			byte_size = config.byte_size or ffi.sizeof(data)
		end
	end

	local buffer = self.device:CreateBuffer(byte_size, config.buffer_usage, config.memory_property)

	if data then buffer:CopyData(data, byte_size) end

	return buffer
end

function VulkanInstance:UploadToImage(image, data, width, height)
	local pixel_count = width * height
	-- Create staging buffer
	local staging_buffer = self.device:CreateBuffer(pixel_count * 4, "transfer_src", {"host_visible", "host_coherent"})
	staging_buffer:CopyData(data, pixel_count * 4)
	-- Copy to image using command buffer
	local cmd_pool = self.device:CreateCommandPool(self.graphics_queue_family)
	local cmd = cmd_pool:CreateCommandBuffer()
	cmd:Begin()
	-- Transition image to transfer dst
	cmd:PipelineBarrier(
		{
			srcStage = "compute",
			dstStage = "transfer",
			imageBarriers = {
				{
					image = image,
					srcAccessMask = "none",
					dstAccessMask = "transfer_write",
					oldLayout = "undefined",
					newLayout = "transfer_dst_optimal",
				},
			},
		}
	)
	-- Copy buffer to image
	cmd:CopyBufferToImage(staging_buffer, image, width, height)
	-- Determine final layout based on image usage
	local final_layout = "general"
	local dst_stage = "compute"

	if type(image.usage) == "table" then
		for _, usage in ipairs(image.usage) do
			if usage == "sampled" then
				final_layout = "shader_read_only_optimal"
				dst_stage = "fragment"

				break
			end
		end
	end

	-- Transition to final layout
	cmd:PipelineBarrier(
		{
			srcStage = "transfer",
			dstStage = dst_stage,
			imageBarriers = {
				{
					image = image,
					srcAccessMask = "transfer_write",
					dstAccessMask = "shader_read",
					oldLayout = "transfer_dst_optimal",
					newLayout = final_layout,
				},
			},
		}
	)
	cmd:End()
	-- Submit and wait
	local fence = self.device:CreateFence()
	self.queue:SubmitAndWait(self.device, cmd, fence)
end

local OffscreenRenderTarget = require("graphics.vulkan.rendertarget_offscreen")
local WindowRenderTarget = require("graphics.vulkan.rendertarget_window")
local Pipeline = require("graphics.vulkan.graphics_pipeline")
local ComputePipeline = require("graphics.vulkan.compute_pipeline")

function VulkanInstance:CreateOffscreenRenderTarget(width, height, format, config)
	return OffscreenRenderTarget.New(self, width, height, format, config)
end

function VulkanInstance:CreateWindowRenderTarget()
	return WindowRenderTarget.New(self)
end

function VulkanInstance:CreatePipeline(...)
	return Pipeline.New(self, ...)
end

function VulkanInstance:CreateComputePipeline(...)
	return ComputePipeline.New(self, ...)
end

return VulkanInstance
