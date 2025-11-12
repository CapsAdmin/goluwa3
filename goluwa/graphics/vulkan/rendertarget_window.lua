local ffi = require("ffi")
local WindowRenderTarget = {}
WindowRenderTarget.__index = WindowRenderTarget

function WindowRenderTarget.New(renderer)
	local self = setmetatable({}, WindowRenderTarget)
	self.renderer = renderer
	self.current_frame = 0
	-- Create depth buffer
	local extent = renderer.surface_capabilities.currentExtent
	local depth_format = "D32_SFLOAT"
	self.depth_image = renderer.device:CreateImage(
		extent.width,
		extent.height,
		depth_format,
		{"depth_stencil_attachment"},
		"device_local"
	)
	self.depth_image_view = renderer.device:CreateImageView(self.depth_image, {format = depth_format, aspect = "depth"})
	-- Create render pass for swapchain format with depth
	self.render_pass = renderer.device:CreateRenderPass(
		{
			format = renderer.surface_formats[renderer.config.surface_format_index],
			depth_format = depth_format,
		}
	)
	-- Create image views for swapchain images
	self.image_views = {}

	for _, swapchain_image in ipairs(renderer.swapchain_images) do
		table.insert(
			self.image_views,
			renderer.device:CreateImageView(
				swapchain_image,
				renderer.surface_formats[renderer.config.surface_format_index].format
			)
		)
	end

	-- Create framebuffers
	self.framebuffers = {}

	for i, imageView in ipairs(self.image_views) do
		table.insert(
			self.framebuffers,
			renderer.device:CreateFramebuffer(
				self.render_pass,
				imageView,
				extent.width,
				extent.height,
				nil,
				self.depth_image_view
			)
		)
	end

	-- Initialize per-frame resources
	self.command_buffers = {}
	self.image_available_semaphores = {}
	self.render_finished_semaphores = {}
	self.in_flight_fences = {}

	for i = 1, #renderer.swapchain_images do
		self.command_buffers[i] = renderer.command_pool:CreateCommandBuffer()
		self.image_available_semaphores[i] = renderer.device:CreateSemaphore()
		self.render_finished_semaphores[i] = renderer.device:CreateSemaphore()
		self.in_flight_fences[i] = renderer.device:CreateFence()
	end

	return self
end

function WindowRenderTarget:GetSwapChainImage()
	return self.renderer.swapchain_images[self.image_index]
end

function WindowRenderTarget:GetRenderPass()
	return self.render_pass
end

function WindowRenderTarget:BeginFrame()
	-- Use round-robin frame index
	self.current_frame = (self.current_frame % #self.renderer.swapchain_images) + 1
	-- Wait for the fence for this frame FIRST
	self.in_flight_fences[self.current_frame]:Wait()
	-- Acquire next image
	local image_index = self.renderer.swapchain:GetNextImage(self.image_available_semaphores[self.current_frame])

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
	self.renderer.queue:Submit(
		command_buffer,
		self.image_available_semaphores[self.current_frame],
		self.render_finished_semaphores[self.current_frame],
		self.in_flight_fences[self.current_frame]
	)

	-- Present and recreate swapchain if needed
	if
		not self.renderer.swapchain:Present(
			self.render_finished_semaphores[self.current_frame],
			self.renderer.queue,
			ffi.new("uint32_t[1]", self.image_index - 1)
		)
	then
		self:RecreateSwapchain()
	end
end

function WindowRenderTarget:RecreateSwapchain()
	self.renderer:RecreateSwapchain()
	-- Recreate depth buffer with new extent
	local extent = self.renderer.surface_capabilities[0].currentExtent
	local depth_format = "D32_SFLOAT"
	self.depth_image = self.renderer.device:CreateImage(
		extent.width,
		extent.height,
		depth_format,
		{"depth_stencil_attachment"},
		"device_local"
	)
	self.depth_image_view = self.renderer.device:CreateImageView(self.depth_image, {format = depth_format, aspect = "depth"})
	-- Recreate image views
	self.image_views = {}

	for _, swapchain_image in ipairs(self.renderer.swapchain_images) do
		table.insert(
			self.image_views,
			self.renderer.device:CreateImageView(
				swapchain_image,
				self.renderer.surface_formats[self.renderer.config.surface_format_index].format
			)
		)
	end

	-- Recreate framebuffers
	self.framebuffers = {}

	for i, imageView in ipairs(self.image_views) do
		table.insert(
			self.framebuffers,
			self.renderer.device:CreateFramebuffer(
				self.render_pass,
				imageView,
				extent.width,
				extent.height,
				nil,
				self.depth_image_view
			)
		)
	end

	-- Recreate per-frame resources if image count changed
	local new_count = #self.renderer.swapchain_images
	local old_count = #self.command_buffers

	if old_count ~= new_count then
		self.command_buffers = {}
		self.image_available_semaphores = {}
		self.render_finished_semaphores = {}
		self.in_flight_fences = {}

		for i = 1, new_count do
			self.command_buffers[i] = self.renderer.command_pool:CreateCommandBuffer()
			self.image_available_semaphores[i] = self.renderer.device:CreateSemaphore()
			self.render_finished_semaphores[i] = self.renderer.device:CreateSemaphore()
			self.in_flight_fences[i] = self.renderer.device:CreateFence()
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
	return self.renderer:GetExtent()
end

return WindowRenderTarget
