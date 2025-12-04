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

local function choose_format(self)
	-- Query surface capabilities and formats
	self.surface_capabilities = self.vulkan_instance.physical_device:GetSurfaceCapabilities(self.vulkan_instance.surface)
	self.surface_formats = self.vulkan_instance.physical_device:GetSurfaceFormats(self.vulkan_instance.surface)

	-- Handle undefined surface size (Wayland)
	if self.surface_capabilities.currentExtent.width == 0xFFFFFFFF then
		print(
			"Surface extent is undefined (0xFFFFFFFF), using window size: " .. (
					self.config.width or
					"nil"
				) .. "x" .. (
					self.config.height or
					"nil"
				)
		)

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

	if self.surface_formats[self.config.surface_format_index].format == "undefined" then
		error("selected surface format is undefined!")
	end

	self.samples = "4"
	self.depth_format = "d32_sfloat"
	self.surface_format = self.surface_formats[self.config.surface_format_index]
	self.color_format = self.surface_format.format
end

local function create_swapchain(self)
	-- Recreate swapchain
	self.swapchain = SwapChain.New(
		{
			device = self.vulkan_instance.device,
			surface = self.vulkan_instance.surface,
			surface_format = self.surface_format,
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
	local Texture = require("graphics.texture")
	local textures = {}

	for i, img in ipairs(self.swapchain:GetImages()) do
		local view = ImageView.New(
			{
				device = self.vulkan_instance.device,
				image = img,
				format = self.surface_format.format,
			}
		)
		textures[i] = setmetatable({image = img, view = view}, Texture)
	end

	self.textures = textures
end

local function create_depth_buffer(self)
	local extent = self.surface_capabilities.currentExtent
	local Texture = require("graphics.texture")
	-- Create the image
	local render = require("graphics.render")
	local Image = require("graphics.vulkan.internal.image")
	local ImageView = require("graphics.vulkan.internal.image_view")
	local image = Image.New(
		{
			device = render.GetDevice(),
			width = extent.width,
			height = extent.height,
			format = self.depth_format,
			usage = {"depth_stencil_attachment"},
			properties = "device_local",
			samples = self.samples,
		}
	)
	local view = ImageView.New(
		{
			device = render.GetDevice(),
			image = image,
			format = self.depth_format,
			aspect = "depth",
		}
	)
	self.depth_texture = setmetatable({image = image, view = view}, Texture)
end

local function create_msaa_buffer(self)
	local extent = self.surface_capabilities.currentExtent
	local Texture = require("graphics.texture")

	-- Recreate MSAA color buffer if using MSAA
	if self.samples ~= "1" then
		-- Create the image directly without transition
		local render = require("graphics.render")
		local Image = require("graphics.vulkan.internal.image")
		local ImageView = require("graphics.vulkan.internal.image_view")
		local image = Image.New(
			{
				device = render.GetDevice(),
				width = extent.width,
				height = extent.height,
				format = self.surface_format.format,
				usage = {"color_attachment"},
				properties = "device_local",
				samples = self.samples,
			}
		)
		local view = ImageView.New(
			{
				device = render.GetDevice(),
				image = image,
				format = self.surface_format.format,
			}
		)
		self.msaa_image = setmetatable({image = image, view = view}, Texture)
	end
end

local function create_per_frame_resources(self)
	if self.command_buffers and #self.command_buffers == #self.textures then
		return
	end

	self.command_buffers = {}
	self.image_available_semaphores = {}
	self.render_finished_semaphores = {}
	self.in_flight_fences = {}

	for i = 1, #self.textures do
		self.command_buffers[i] = self.vulkan_instance.command_pool:AllocateCommandBuffer()
		self.image_available_semaphores[i] = Semaphore.New(self.vulkan_instance.device)
		self.render_finished_semaphores[i] = Semaphore.New(self.vulkan_instance.device)
		self.in_flight_fences[i] = Fence.New(self.vulkan_instance.device)
	end

	self.current_frame = 0
end

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
	choose_format(self)
	create_swapchain(self)
	create_depth_buffer(self)
	create_msaa_buffer(self)
	create_per_frame_resources(self)
	return self
end

function WindowRenderTarget:GetSwapChainImage()
	return self.textures[self.texture_index]:GetImage()
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
	return self.textures[self.texture_index]:GetView()
end

function WindowRenderTarget:GetMSAAImageView()
	return self.msaa_image:GetView()
end

function WindowRenderTarget:GetDepthImageView()
	return self.depth_texture:GetView()
end

function WindowRenderTarget:BeginFrame()
	-- Use round-robin frame index
	self.current_frame = (self.current_frame % #self.textures) + 1
	-- Wait for the fence for this frame FIRST
	self.in_flight_fences[self.current_frame]:Wait()
	-- Acquire next image using current_frame semaphore for acquisition
	local texture_index = self.swapchain:GetNextImage(self.image_available_semaphores[self.current_frame])

	-- Check if swapchain needs recreation
	if texture_index == nil then
		self:RebuildFramebuffers()
		return nil
	end

	self.texture_index = texture_index + 1
	-- Reset command buffer for this frame (but don't begin yet - that happens after descriptor updates)
	self.command_buffers[self.current_frame]:Reset()
	self:BeginCommandBuffer()
	local cmd = self:GetCommandBuffer()
	-- Transition swapchain image to color attachment optimal
	cmd:PipelineBarrier(
		{
			srcStage = "color_attachment_output",
			dstStage = "color_attachment_output",
			imageBarriers = {
				{
					image = self:GetSwapChainImage(),
					srcAccessMask = "none",
					dstAccessMask = "color_attachment_write",
					oldLayout = "undefined",
					newLayout = "color_attachment_optimal",
				},
			},
		}
	)
	local extent = self:GetExtent()
	cmd:BeginRendering(
		{
			color_image_view = self:GetImageView(),
			msaa_image_view = self:GetMSAAImageView(),
			depth_image_view = self:GetDepthImageView(),
			w = extent.width,
			h = extent.height,
			clear_color = {0.2, 0.2, 0.2, 1.0},
			clear_depth = 1.0,
		}
	)
	cmd:SetViewport(0, 0, extent.width, extent.height, 0, 1)
	cmd:SetScissor(0, 0, extent.width, extent.height)
	return cmd
end

function WindowRenderTarget:BeginCommandBuffer()
	-- Begin command buffer recording
	self.command_buffers[self.current_frame]:Begin()
end

function WindowRenderTarget:EndFrame()
	local command_buffer = self.command_buffers[self.current_frame]
	command_buffer:EndRendering()
	-- Transition swapchain image to present src
	command_buffer:PipelineBarrier(
		{
			srcStage = "color_attachment_output",
			dstStage = "color_attachment_output",
			imageBarriers = {
				{
					image = self:GetSwapChainImage(),
					srcAccessMask = "color_attachment_write",
					dstAccessMask = "none",
					oldLayout = "color_attachment_optimal",
					newLayout = "present_src_khr",
				},
			},
		}
	)
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
			ffi.new("uint32_t[1]", self.texture_index - 1)
		)
	then
		self:RebuildFramebuffers()
	end
end

function WindowRenderTarget:RebuildFramebuffers()
	-- Wait for device to be idle
	self.vulkan_instance.device:WaitIdle()
	choose_format(self)
	create_swapchain(self)
	create_depth_buffer(self)
	create_msaa_buffer(self)
	create_per_frame_resources(self)
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
	return #self.textures
end

return WindowRenderTarget
