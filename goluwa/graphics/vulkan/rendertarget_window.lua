local ffi = require("ffi")
local Image = require("graphics.vulkan.internal.image")
local ImageView = require("graphics.vulkan.internal.image_view")
local RenderPass = require("graphics.vulkan.internal.render_pass")
local Framebuffer = require("graphics.vulkan.internal.framebuffer")
local CommandBuffer = require("graphics.vulkan.internal.command_buffer")
local Semaphore = require("graphics.vulkan.internal.semaphore")
local Fence = require("graphics.vulkan.internal.fence")
local WindowRenderTarget = {}
WindowRenderTarget.__index = WindowRenderTarget

function WindowRenderTarget.New(render_instance)
	local self = setmetatable({}, WindowRenderTarget)
	self.render_instance = render_instance
	self.current_frame = 0
	local samples = "4"
	-- Create depth buffer
	local extent = render_instance.surface_capabilities.currentExtent
	local depth_format = "D32_SFLOAT"
	self.depth_image = Image.New(
		{
			device = render_instance.device,
			width = extent.width,
			height = extent.height,
			format = depth_format,
			usage = {"depth_stencil_attachment"},
			properties = "device_local",
			samples = samples,
		}
	)
	self.depth_image_view = ImageView.New(render_instance.device, self.depth_image, {format = depth_format, aspect = "depth"})

	-- Create MSAA color buffer if using MSAA
	if samples ~= "1" then
		local format = render_instance.surface_formats[render_instance.config.surface_format_index].format
		self.msaa_image = Image.New(
			{
				device = render_instance.device,
				width = extent.width,
				height = extent.height,
				format = format,
				usage = {"color_attachment"},
				properties = "device_local",
				samples = samples,
			}
		)
		self.msaa_image_view = ImageView.New(render_instance.device, self.msaa_image, format)
	end

	-- Create render pass for swapchain format with depth
	self.render_pass = RenderPass.New(
		render_instance.device,
		{
			format = render_instance.surface_formats[render_instance.config.surface_format_index],
			depth_format = depth_format,
			samples = samples,
		}
	)
	-- Create image views for swapchain images
	self.image_views = {}

	for _, swapchain_image in ipairs(render_instance.swapchain_images) do
		table.insert(
			self.image_views,
			ImageView.New(
				render_instance.device,
				swapchain_image,
				render_instance.surface_formats[render_instance.config.surface_format_index].format
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
					device = render_instance.device,
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

	for i = 1, #render_instance.swapchain_images do
		self.command_buffers[i] = render_instance.command_pool:AllocateCommandBuffer()
		self.image_available_semaphores[i] = Semaphore.New(render_instance.device)
		self.render_finished_semaphores[i] = Semaphore.New(render_instance.device)
		self.in_flight_fences[i] = Fence.New(render_instance.device)
	end

	return self
end

function WindowRenderTarget:GetSwapChainImage()
	return self.render_instance.swapchain_images[self.image_index]
end

function WindowRenderTarget:GetRenderPass()
	return self.render_pass
end

function WindowRenderTarget:BeginFrame()
	-- Use round-robin frame index
	self.current_frame = (self.current_frame % #self.render_instance.swapchain_images) + 1
	-- Wait for the fence for this frame FIRST
	self.in_flight_fences[self.current_frame]:Wait()
	-- Acquire next image
	local image_index = self.render_instance.swapchain:GetNextImage(self.image_available_semaphores[self.current_frame])

	-- Check if swapchain needs recreation
	if image_index == nil then
		self:RecreateSwapchain()
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
	self.render_instance.queue:Submit(
		command_buffer,
		self.image_available_semaphores[self.current_frame],
		self.render_finished_semaphores[self.current_frame],
		self.in_flight_fences[self.current_frame]
	)

	-- Present and recreate swapchain if needed
	if
		not self.render_instance.swapchain:Present(
			self.render_finished_semaphores[self.current_frame],
			self.render_instance.queue,
			ffi.new("uint32_t[1]", self.image_index - 1)
		)
	then
		self:RecreateSwapchain()
	end
end

function WindowRenderTarget:RecreateSwapchain()
	self.render_instance:RecreateSwapchain()
	-- Recreate depth buffer with new extent
	local extent = self.render_instance.surface_capabilities[0].currentExtent
	local depth_format = "D32_SFLOAT"
	local samples = self.render_pass.samples
	self.depth_image = Image.New(
		{
			device = self.render_instance.device,
			width = extent.width,
			height = extent.height,
			format = depth_format,
			usage = {"depth_stencil_attachment"},
			properties = "device_local",
			samples = samples,
		}
	)
	self.depth_image_view = ImageView.New(self.render_instance.device, self.depth_image, {format = depth_format, aspect = "depth"})

	-- Recreate MSAA color buffer if using MSAA
	if samples ~= "1" then
		local format = self.render_instance.surface_formats[self.render_instance.config.surface_format_index].format
		self.msaa_image = Image.New(
			{
				device = self.render_instance.device,
				width = extent.width,
				height = extent.height,
				format = format,
				usage = {"color_attachment"},
				properties = "device_local",
				samples = samples,
			}
		)
		self.msaa_image_view = ImageView.New(self.render_instance.device, self.msaa_image, format)
	end

	-- Recreate image views
	self.image_views = {}

	for _, swapchain_image in ipairs(self.render_instance.swapchain_images) do
		table.insert(
			self.image_views,
			ImageView.New(
				self.render_instance.device,
				swapchain_image,
				self.render_instance.surface_formats[self.render_instance.config.surface_format_index].format
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
					device = self.render_instance.device,
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
	local new_count = #self.render_instance.swapchain_images
	local old_count = #self.command_buffers

	if old_count ~= new_count then
		self.command_buffers = {}
		self.image_available_semaphores = {}
		self.render_finished_semaphores = {}
		self.in_flight_fences = {}

		for i = 1, new_count do
			self.command_buffers[i] = self.render_instance.command_pool:AllocateCommandBuffer()
			self.image_available_semaphores[i] = Semaphore.New(self.render_instance.device)
			self.render_finished_semaphores[i] = Semaphore.New(self.render_instance.device)
			self.in_flight_fences[i] = Fence.New(self.render_instance.device)
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
	return self.render_instance:GetExtent()
end

return WindowRenderTarget
