local ffi = require("ffi")
local Instance = require("graphics.vulkan.internal.instance")
local Device = require("graphics.vulkan.internal.device")
local PhysicalDevice = require("graphics.vulkan.internal.physical_device")
local Buffer = require("graphics.vulkan.internal.buffer")
local CommandBuffer = require("graphics.vulkan.internal.command_buffer")
local CommandPool = require("graphics.vulkan.internal.command_pool")
local ComputePipeline = require("graphics.vulkan.internal.compute_pipeline")
local DescriptorPool = require("graphics.vulkan.internal.descriptor_pool")
local DescriptorSetLayout = require("graphics.vulkan.internal.descriptor_set_layout")
local Fence = require("graphics.vulkan.internal.fence")
local Framebuffer = require("graphics.vulkan.internal.framebuffer")
local GraphicsPipeline = require("graphics.vulkan.internal.graphics_pipeline")
local Image = require("graphics.vulkan.internal.image")
local ImageView = require("graphics.vulkan.internal.image_view")
local PipelineLayout = require("graphics.vulkan.internal.pipeline_layout")
local Queue = require("graphics.vulkan.internal.queue")
local RenderPass = require("graphics.vulkan.internal.render_pass")
local Sampler = require("graphics.vulkan.internal.sampler")
local Semaphore = require("graphics.vulkan.internal.semaphore")
local ShaderModule = require("graphics.vulkan.internal.shader_module")
local SwapChain = require("graphics.vulkan.internal.swap_chain")
local Surface = require("graphics.vulkan.internal.surface")
local process = require("bindings.process")
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
	local metal_surface = assert(self.config.surface_handle)
	local layers = {}
	local VULKAN_SDK = "/Users/caps/VulkanSDK/1.4.328.1"
	process.setenv("VULKAN_SDK", VULKAN_SDK)
	process.setenv("VK_LAYER_PATH", VULKAN_SDK .. "/macOS/share/vulkan/explicit_layer.d")
	local extensions = {"VK_KHR_surface", "VK_EXT_metal_surface"}
	table.insert(layers, "VK_LAYER_KHRONOS_validation")
	table.insert(extensions, "VK_KHR_portability_enumeration")
	self.instance = Instance.New(extensions, layers)
	self.surface = Surface.New(self.instance, metal_surface)
	self.physical_device = self.instance:GetPhysicalDevices()[1]
	self.graphics_queue_family = self.physical_device:FindGraphicsQueueFamily(self.surface)
	-- Try to enable dynamic blend extension if available
	local device_extensions = {"VK_KHR_swapchain"}
	-- Check if VK_EXT_extended_dynamic_state3 is available
	local available_extensions = self.physical_device:GetAvailableDeviceExtensions()

	for _, ext in ipairs(available_extensions) do
		if ext == "VK_EXT_extended_dynamic_state3" then
			table.insert(device_extensions, "VK_EXT_extended_dynamic_state3")

			break
		end
	end

	self.device = Device.New(self.physical_device, device_extensions, self.graphics_queue_family)
	self.command_pool = CommandPool.New(self.device, self.graphics_queue_family)
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
		image_count = self.config.image_count or (self.surface_capabilities.minImageCount + 1),
		composite_alpha = self.config.composite_alpha,
		clipped = self.config.clipped,
		image_usage = self.config.image_usage,
		pre_transform = self.config.pre_transform,
	}
	-- Create new swapchain (pass old swapchain if it exists)
	self.swapchain = SwapChain.New(
		self.device,
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
	return self.surface_capabilities.currentExtent
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

	local buffer = Buffer.New(
		{
			device = self.device,
			size = byte_size,
			usage = config.buffer_usage,
			properties = config.memory_property,
		}
	)

	if data then buffer:CopyData(data, byte_size) end

	return buffer
end

function VulkanInstance:UploadToImage(image, data, width, height, keep_in_transfer_dst)
	local pixel_count = width * height
	-- Create staging buffer
	local staging_buffer = Buffer.New(
		{
			device = self.device,
			size = pixel_count * 4,
			usage = "transfer_src",
			properties = {"host_visible", "host_coherent"},
		}
	)
	staging_buffer:CopyData(data, pixel_count * 4)
	-- Copy to image using command buffer
	local cmd_pool = CommandPool.New(self.device, self.graphics_queue_family)
	local cmd = cmd_pool:AllocateCommandBuffer()
	cmd:Begin()
	-- Transition image to transfer dst (only mip level 0)
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
					base_mip_level = 0,
					level_count = 1,
				},
			},
		}
	)
	-- Copy buffer to image
	cmd:CopyBufferToImage(staging_buffer, image, width, height)

	-- Only transition to final layout if not keeping in transfer_dst for mipmap generation
	if not keep_in_transfer_dst then
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
						base_mip_level = 0,
						level_count = 1,
					},
				},
			}
		)
	end

	cmd:End()
	-- Submit and wait
	local fence = Fence.New(self.device)
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

function VulkanInstance:CreateGraphicsPipeline(...)
	return Pipeline.New(self, ...)
end

function VulkanInstance:CreateComputePipeline(...)
	return ComputePipeline.New(self, ...)
end

return VulkanInstance
