local ffi = require("ffi")
local Image = require("graphics.vulkan.internal.image")
local ImageView = require("graphics.vulkan.internal.image_view")
local CommandBuffer = require("graphics.vulkan.internal.command_buffer")
local Semaphore = require("graphics.vulkan.internal.semaphore")
local Fence = require("graphics.vulkan.internal.fence")
local SwapChain = require("graphics.vulkan.internal.swap_chain")
local WindowRenderTarget = {}
WindowRenderTarget.__index = WindowRenderTarget
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
	width = 512,
	height = 512,
}

function WindowRenderTarget.New(vulkan_instance, config)
	config = config or {}

	for k, v in pairs(default_config) do
		if config[k] == nil then config[k] = v end
	end

	if config.width == 0 then config.width = 512 end
	if config.height == 0 then config.height = 512 end

	local self = setmetatable({config = config}, WindowRenderTarget)
	self.vulkan_instance = vulkan_instance
	self.current_frame = 0
	-- Query surface capabilities and formats
	self.surface_capabilities = vulkan_instance.physical_device:GetSurfaceCapabilities(self.vulkan_instance.surface)
	self.surface_formats = vulkan_instance.physical_device:GetSurfaceFormats(self.vulkan_instance.surface)
	
	-- Handle undefined surface size (Wayland)
	if self.surface_capabilities.currentExtent.width == 0xFFFFFFFF then
		print("Surface extent is undefined (0xFFFFFFFF), using window size: " .. (self.config.width or "nil") .. "x" .. (self.config.height or "nil"))
		if self.config.width and self.config.height then
			self.surface_capabilities.currentExtent.width = self.config.width
			self.surface_capabilities.currentExtent.height = self.config.height
		else
			error("Surface extent is undefined and no window size provided in config!")
		end
	end

	-- Validate format index
	if #self.surface_formats == 0 then
		error("No surface formats available! Surface may not be properly initialized.")
	end

	if self.config.surface_format_index > #self.surface_formats then
		error(
			"Invalid surface_format_index: " .. self.config.surface_format_index .. " (max: " .. (
					#self.surface_formats
				) .. ")"
		)
	end

	local selected_format = self.surface_formats[self.config.surface_format_index]

	if selected_format.format == "undefined" then
		error("selected surface format is undefined!")
	end

	-- Create swapchain
	self.swapchain = SwapChain.New(
		{
			device = vulkan_instance.device,
			surface = self.vulkan_instance.surface,
			surface_format = self.surface_formats[self.config.surface_format_index],
			surface_capabilities = self.surface_capabilities,
			image_count = self.config.image_count or
				(
					self.surface_capabilities.minImageCount + 1
				),
			present_mode = self.config.present_mode,
			composite_alpha = self.config.composite_alpha,
			clipped = self.config.clipped,
			image_usage = self.config.image_usage,
			pre_transform = self.config.pre_transform,
		}
	)
	self.swapchain_images = self.swapchain:GetImages()
	self.samples = "4"
	self.depth_format = "D32_SFLOAT"
	self.color_format = self.surface_formats[self.config.surface_format_index].format
	local extent = self.surface_capabilities.currentExtent
	self.depth_image = Image.New(
		{
			device = vulkan_instance.device,
			width = extent.width,
			height = extent.height,
			format = self.depth_format,
			usage = {"depth_stencil_attachment"},
			properties = "device_local",
			samples = self.samples,
		}
	)
	self.depth_image_view = ImageView.New(
		{
			device = vulkan_instance.device,
			image = self.depth_image,
			format = self.depth_format,
			aspect = "depth",
		}
	)

	-- Create MSAA color buffer if using MSAA
	if self.samples ~= "1" then
		self.msaa_image = Image.New(
			{
				device = vulkan_instance.device,
				width = extent.width,
				height = extent.height,
				format = self.color_format,
				usage = {"color_attachment"},
				properties = "device_local",
				samples = self.samples,
			}
		)
		self.msaa_image_view = ImageView.New(
			{
				device = vulkan_instance.device,
				image = self.msaa_image,
				format = self.color_format,
			}
		)
	end

	-- Create image views for swapchain images
	self.image_views = {}

	for _, swapchain_image in ipairs(self.swapchain_images) do
		table.insert(
			self.image_views,
			ImageView.New(
				{
					device = vulkan_instance.device,
					image = swapchain_image,
					format = self.surface_formats[self.config.surface_format_index].format,
				}
			)
		)
	end

	-- Initialize per-frame resources
	self.command_buffers = {}
	self.image_available_semaphores = {}
	self.render_finished_semaphores = {}
	self.in_flight_fences = {}

	for i = 1, #self.swapchain_images do
		self.command_buffers[i] = vulkan_instance.command_pool:AllocateCommandBuffer()
		self.image_available_semaphores[i] = Semaphore.New(vulkan_instance.device)
		self.render_finished_semaphores[i] = Semaphore.New(vulkan_instance.device)
		self.in_flight_fences[i] = Fence.New(vulkan_instance.device)
	end

	return self
end

function WindowRenderTarget:GetSwapChainImage()
	return self.swapchain_images[self.image_index]
end

function WindowRenderTarget:GetColorFormat()
	return self.color_format
end

function WindowRenderTarget:GetDepthFormat()
	return self.depth_format
end

function WindowRenderTarget:GetSamples()
	return self.samples
end

function WindowRenderTarget:GetImageView()
	return self.image_views[self.image_index]
end

function WindowRenderTarget:GetMSAAImageView()
	return self.msaa_image_view
end

function WindowRenderTarget:GetDepthImageView()
	return self.depth_image_view
end

function WindowRenderTarget:BeginFrame()
	-- Use round-robin frame index
	self.current_frame = (self.current_frame % #self.swapchain_images) + 1
	-- Wait for the fence for this frame FIRST
	self.in_flight_fences[self.current_frame]:Wait()
	-- Acquire next image
	local image_index = self.swapchain:GetNextImage(self.image_available_semaphores[self.current_frame])

	-- Check if swapchain needs recreation
	if image_index == nil then
		self:RebuildFramebuffers()
		return nil
	end

	self.image_index = image_index + 1
	-- Reset command buffer for this frame (but don't begin yet - that happens after descriptor updates)
	self.command_buffers[self.current_frame]:Reset()
	return true
end

function WindowRenderTarget:BeginCommandBuffer()
	-- Begin command buffer recording
	self.command_buffers[self.current_frame]:Begin()
end

function WindowRenderTarget:EndFrame()
	local command_buffer = self.command_buffers[self.current_frame]
	command_buffer:End()
	-- Submit command buffer with current frame's semaphores
	self.vulkan_instance.queue:Submit(
		command_buffer,
		self.image_available_semaphores[self.current_frame],
		self.render_finished_semaphores[self.current_frame],
		self.in_flight_fences[self.current_frame]
	)

	-- Present and recreate swapchain if needed
	if
		not self.swapchain:Present(
			self.render_finished_semaphores[self.current_frame],
			self.vulkan_instance.queue,
			ffi.new("uint32_t[1]", self.image_index - 1)
		)
	then
		self:RebuildFramebuffers()
	end
end

function WindowRenderTarget:RebuildFramebuffers()
	-- Wait for device to be idle
	self.vulkan_instance.device:WaitIdle()
	-- Query surface capabilities and formats
	self.surface_capabilities = self.vulkan_instance.physical_device:GetSurfaceCapabilities(self.vulkan_instance.surface)
	self.surface_formats = self.vulkan_instance.physical_device:GetSurfaceFormats(self.vulkan_instance.surface)

	-- Handle undefined surface size (Wayland)
	if self.surface_capabilities.currentExtent.width == 0xFFFFFFFF then
		print("Surface extent is undefined (0xFFFFFFFF) during rebuild, using window size: " .. (self.config.width or "nil") .. "x" .. (self.config.height or "nil"))
		if self.config.width and self.config.height then
			self.surface_capabilities.currentExtent.width = self.config.width
			self.surface_capabilities.currentExtent.height = self.config.height
		else
			error("Surface extent is undefined and no window size provided in config!")
		end
	end

	-- Validate format index
	if self.config.surface_format_index > #self.surface_formats then
		error(
			"Invalid surface_format_index: " .. self.config.surface_format_index .. " (max: " .. (
					#self.surface_formats
				) .. ")"
		)
	end

	local selected_format = self.surface_formats[self.config.surface_format_index]

	if selected_format.format == "undefined" then
		error("selected surface format is undefined!")
	end

	-- Recreate swapchain
	self.swapchain = SwapChain.New(
		{
			device = self.vulkan_instance.device,
			surface = self.vulkan_instance.surface,
			surface_format = self.surface_formats[self.config.surface_format_index],
			surface_capabilities = self.surface_capabilities,
			image_count = self.config.image_count or
				(
					self.surface_capabilities.minImageCount + 1
				),
			present_mode = self.config.present_mode,
			composite_alpha = self.config.composite_alpha,
			clipped = self.config.clipped,
			image_usage = self.config.image_usage,
			pre_transform = self.config.pre_transform,
			old_swapchain = self.swapchain,
		}
	)
	self.swapchain_images = self.swapchain:GetImages()
	-- Recreate depth buffer with new extent
	local extent = self.surface_capabilities.currentExtent
	self.depth_image = Image.New(
		{
			device = self.vulkan_instance.device,
			width = extent.width,
			height = extent.height,
			format = self.depth_format,
			usage = {"depth_stencil_attachment"},
			properties = "device_local",
			samples = self.samples,
		}
	)
	self.depth_image_view = ImageView.New(
		{
			device = self.vulkan_instance.device,
			image = self.depth_image,
			format = self.depth_format,
			aspect = "depth",
		}
	)

	-- Recreate MSAA color buffer if using MSAA
	if self.samples ~= "1" then
		self.msaa_image = Image.New(
			{
				device = self.vulkan_instance.device,
				width = extent.width,
				height = extent.height,
				format = self.color_format,
				usage = {"color_attachment"},
				properties = "device_local",
				samples = self.samples,
			}
		)
		self.msaa_image_view = ImageView.New(
			{
				device = self.vulkan_instance.device,
				image = self.msaa_image,
				format = self.color_format,
			}
		)
	end

	-- Recreate image views
	self.image_views = {}

	for _, swapchain_image in ipairs(self.swapchain_images) do
		table.insert(
			self.image_views,
			ImageView.New(
				{
					device = self.vulkan_instance.device,
					image = swapchain_image,
					format = self.surface_formats[self.config.surface_format_index].format,
				}
			)
		)
	end

	-- Recreate per-frame resources if image count changed
	local new_count = #self.swapchain_images
	local old_count = #self.command_buffers

	if old_count ~= new_count then
		self.command_buffers = {}
		self.image_available_semaphores = {}
		self.render_finished_semaphores = {}
		self.in_flight_fences = {}

		for i = 1, new_count do
			self.command_buffers[i] = self.vulkan_instance.command_pool:AllocateCommandBuffer()
			self.image_available_semaphores[i] = Semaphore.New(self.vulkan_instance.device)
			self.render_finished_semaphores[i] = Semaphore.New(self.vulkan_instance.device)
			self.in_flight_fences[i] = Fence.New(self.vulkan_instance.device)
		end

		self.current_frame = 0
	end
end

function WindowRenderTarget:GetCommandBuffer()
	return self.command_buffers[self.current_frame]
end

function WindowRenderTarget:GetCurrentFrame()
	return self.current_frame
end

function WindowRenderTarget:GetExtent()
	return self.surface_capabilities.currentExtent
end

function WindowRenderTarget:GetSwapchainImageCount()
	return #self.swapchain_images
end

return WindowRenderTarget
