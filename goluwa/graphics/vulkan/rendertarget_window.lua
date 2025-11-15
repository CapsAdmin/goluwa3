local ffi = require("ffi")
local Image = require("graphics.vulkan.internal.image")
local ImageView = require("graphics.vulkan.internal.image_view")
local RenderPass = require("graphics.vulkan.internal.render_pass")
local Framebuffer = require("graphics.vulkan.internal.framebuffer")
local CommandBuffer = require("graphics.vulkan.internal.command_buffer")
local Semaphore = require("graphics.vulkan.internal.semaphore")
local Fence = require("graphics.vulkan.internal.fence")
local SwapChain = require("graphics.vulkan.internal.swap_chain")
local WindowRenderTarget = {}
WindowRenderTarget.__index = WindowRenderTarget

function WindowRenderTarget.New(vulkan_instance)
	local self = setmetatable({}, WindowRenderTarget)
	self.vulkan_instance = vulkan_instance
	self.current_frame = 0
	-- Query surface capabilities and formats
	self.surface_capabilities = vulkan_instance.physical_device:GetSurfaceCapabilities(vulkan_instance.surface)
	self.surface_formats = vulkan_instance.physical_device:GetSurfaceFormats(vulkan_instance.surface)

	-- Validate format index
	if vulkan_instance.config.surface_format_index > #self.surface_formats then
		error(
			"Invalid surface_format_index: " .. vulkan_instance.config.surface_format_index .. " (max: " .. (
					#self.surface_formats
				) .. ")"
		)
	end

	local selected_format = self.surface_formats[vulkan_instance.config.surface_format_index]

	if selected_format.format == "undefined" then
		error("selected surface format is undefined!")
	end

	-- Create swapchain
	self.swapchain = SwapChain.New(
		{
			device = vulkan_instance.device,
			surface = vulkan_instance.surface,
			surface_format = self.surface_formats[vulkan_instance.config.surface_format_index],
			surface_capabilities = self.surface_capabilities,
			image_count = vulkan_instance.config.image_count or
				(
					self.surface_capabilities.minImageCount + 1
				),
			present_mode = vulkan_instance.config.present_mode,
			composite_alpha = vulkan_instance.config.composite_alpha,
			clipped = vulkan_instance.config.clipped,
			image_usage = vulkan_instance.config.image_usage,
			pre_transform = vulkan_instance.config.pre_transform,
		}
	)
	self.swapchain_images = self.swapchain:GetImages()
	local samples = "4"
	-- Create depth buffer
	local extent = self.surface_capabilities.currentExtent
	local depth_format = "D32_SFLOAT"
	self.depth_image = Image.New(
		{
			device = vulkan_instance.device,
			width = extent.width,
			height = extent.height,
			format = depth_format,
			usage = {"depth_stencil_attachment"},
			properties = "device_local",
			samples = samples,
		}
	)
	self.depth_image_view = ImageView.New(
		{
			device = vulkan_instance.device,
			image = self.depth_image,
			format = depth_format,
			aspect = "depth",
		}
	)

	-- Create MSAA color buffer if using MSAA
	if samples ~= "1" then
		local format = self.surface_formats[vulkan_instance.config.surface_format_index].format
		self.msaa_image = Image.New(
			{
				device = vulkan_instance.device,
				width = extent.width,
				height = extent.height,
				format = format,
				usage = {"color_attachment"},
				properties = "device_local",
				samples = samples,
			}
		)
		self.msaa_image_view = ImageView.New({device = vulkan_instance.device, image = self.msaa_image, format = format})
	end

	-- Create render pass for swapchain format with depth
	self.render_pass = RenderPass.New(
		vulkan_instance.device,
		{
			format = self.surface_formats[vulkan_instance.config.surface_format_index],
			depth_format = depth_format,
			samples = samples,
		}
	)
	-- Create image views for swapchain images
	self.image_views = {}

	for _, swapchain_image in ipairs(self.swapchain_images) do
		table.insert(
			self.image_views,
			ImageView.New(
				{
					device = vulkan_instance.device,
					image = swapchain_image,
					format = self.surface_formats[vulkan_instance.config.surface_format_index].format,
				}
			)
		)
	end

	-- Create framebuffers
	self.framebuffers = {}

	for i, imageView in ipairs(self.image_views) do
		table.insert(
			self.framebuffers,
			Framebuffer.New(
				{
					device = vulkan_instance.device,
					render_pass = self.render_pass,
					image_view = imageView,
					width = extent.width,
					height = extent.height,
					msaa_image_view = self.msaa_image_view,
					depth_image_view = self.depth_image_view,
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

function WindowRenderTarget:GetRenderPass()
	return self.render_pass
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

	-- Validate format index
	if self.vulkan_instance.config.surface_format_index > #self.surface_formats then
		error(
			"Invalid surface_format_index: " .. self.vulkan_instance.config.surface_format_index .. " (max: " .. (
					#self.surface_formats
				) .. ")"
		)
	end

	local selected_format = self.surface_formats[self.vulkan_instance.config.surface_format_index]

	if selected_format.format == "undefined" then
		error("selected surface format is undefined!")
	end

	-- Recreate swapchain
	self.swapchain = SwapChain.New(
		{
			device = self.vulkan_instance.device,
			surface = self.vulkan_instance.surface,
			surface_format = self.surface_formats[self.vulkan_instance.config.surface_format_index],
			surface_capabilities = self.surface_capabilities,
			image_count = self.vulkan_instance.config.image_count or
				(
					self.surface_capabilities.minImageCount + 1
				),
			present_mode = self.vulkan_instance.config.present_mode,
			composite_alpha = self.vulkan_instance.config.composite_alpha,
			clipped = self.vulkan_instance.config.clipped,
			image_usage = self.vulkan_instance.config.image_usage,
			pre_transform = self.vulkan_instance.config.pre_transform,
			old_swapchain = self.swapchain,
		}
	)
	self.swapchain_images = self.swapchain:GetImages()
	-- Recreate depth buffer with new extent
	local extent = self.surface_capabilities.currentExtent
	local depth_format = "D32_SFLOAT"
	local samples = self.render_pass.samples
	self.depth_image = Image.New(
		{
			device = self.vulkan_instance.device,
			width = extent.width,
			height = extent.height,
			format = depth_format,
			usage = {"depth_stencil_attachment"},
			properties = "device_local",
			samples = samples,
		}
	)
	self.depth_image_view = ImageView.New(
		{
			device = self.vulkan_instance.device,
			image = self.depth_image,
			format = depth_format,
			aspect = "depth",
		}
	)

	-- Recreate MSAA color buffer if using MSAA
	if samples ~= "1" then
		local format = self.surface_formats[self.vulkan_instance.config.surface_format_index].format
		self.msaa_image = Image.New(
			{
				device = self.vulkan_instance.device,
				width = extent.width,
				height = extent.height,
				format = format,
				usage = {"color_attachment"},
				properties = "device_local",
				samples = samples,
			}
		)
		self.msaa_image_view = ImageView.New({device = self.vulkan_instance.device, image = self.msaa_image, format = format})
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
					format = self.surface_formats[self.vulkan_instance.config.surface_format_index].format,
				}
			)
		)
	end

	-- Recreate framebuffers
	self.framebuffers = {}

	for i, imageView in ipairs(self.image_views) do
		table.insert(
			self.framebuffers,
			Framebuffer.New(
				{
					device = self.vulkan_instance.device,
					render_pass = self.render_pass,
					image_view = imageView,
					width = extent.width,
					height = extent.height,
					msaa_image_view = self.msaa_image_view,
					depth_image_view = self.depth_image_view,
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

function WindowRenderTarget:GetFramebuffer()
	return self.framebuffers[self.image_index]
end

function WindowRenderTarget:GetExtent()
	return self.surface_capabilities.currentExtent
end

function WindowRenderTarget:GetSwapchainImageCount()
	return #self.swapchain_images
end

return WindowRenderTarget
