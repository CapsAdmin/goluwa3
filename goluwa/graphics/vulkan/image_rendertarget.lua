local ffi = require("ffi")
local Image = require("graphics.vulkan.internal.image")
local ImageView = require("graphics.vulkan.internal.image_view")
local CommandBuffer = require("graphics.vulkan.internal.command_buffer")
local Semaphore = require("graphics.vulkan.internal.semaphore")
local Fence = require("graphics.vulkan.internal.fence")
local SwapChain = require("graphics.vulkan.internal.swap_chain")
local RenderPass = require("graphics.vulkan.internal.render_pass")
local Framebuffer = require("graphics.vulkan.internal.framebuffer")
local Texture = require("graphics.texture")
local event = require("event")
local ImageRenderTarget = {}
ImageRenderTarget.__index = ImageRenderTarget
local default_config = {
	-- Mode selection
	offscreen = false, -- Set to true for offscreen rendering
	-- Swapchain settings (windowed mode only)
	present_mode = "fifo_khr", -- FIFO (vsync), IMMEDIATE (no vsync), MAILBOX (triple buffer)
	image_count = nil, -- nil = minImageCount + 1 (usually triple buffer)
	surface_format_index = 1, -- Which format from available formats to use
	composite_alpha = "opaque_khr", -- OPAQUE, PRE_MULTIPLIED, POST_MULTIPLIED, INHERIT
	clipped = true, -- Clip pixels obscured by other windows
	image_usage = nil, -- nil = COLOR_ATTACHMENT | TRANSFER_DST, or provide custom flags
	-- Image acquisition
	acquire_timeout = ffi.cast("uint64_t", -1), -- Infinite timeout by default
	-- Presentation
	pre_transform = nil, -- nil = use currentTransform
	-- Dimensions
	width = 512,
	height = 512,
	-- Offscreen mode settings
	format = nil, -- Format for offscreen rendering (defaults to chosen surface format or "r8g8b8a8_unorm")
	usage = nil, -- Usage flags for offscreen image (defaults to {"color_attachment", "sampled"})
	samples = nil, -- Sample count (defaults to "1" for offscreen, "4" for windowed)
	final_layout = "color_attachment_optimal", -- Final layout for offscreen image
}

local function choose_format(self)
	if self.config.offscreen then
		-- Offscreen mode: use provided format or default
		self.color_format = self.config.format or "r8g8b8a8_unorm"
		self.samples = self.config.samples or "1"
		self.depth_format = "d32_sfloat"
		self.final_layout = self.config.final_layout or "color_attachment_optimal"
		-- Set extent directly from config
		self.extent = {width = self.config.width, height = self.config.height}
		return
	end

	-- Windowed mode: query surface capabilities and formats
	self.surface_capabilities = self.vulkan_instance.physical_device:GetSurfaceCapabilities(self.vulkan_instance.surface)
	self.surface_formats = self.vulkan_instance.physical_device:GetSurfaceFormats(self.vulkan_instance.surface)

	-- Handle undefined surface size (Wayland)
	if self.surface_capabilities.currentExtent.width == 0xFFFFFFFF then
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

	self.samples = self.config.samples or "4"
	self.depth_format = "d32_sfloat"
	self.surface_format = self.surface_formats[self.config.surface_format_index]
	self.color_format = self.surface_format.format
end

local function create_swapchain(self)
	if self.config.offscreen then
		-- Offscreen mode: create a single color attachment image
		local usage = self.config.usage or {"color_attachment", "sampled"}
		local texture = Texture.New(
			{
				width = self.extent.width,
				height = self.extent.height,
				format = self.color_format,
				buffer = false, -- Don't upload any data, and skip automatic layout transition
				image = {
					width = self.extent.width,
					height = self.extent.height,
					format = self.color_format,
					usage = usage,
					properties = "device_local",
					samples = self.samples,
				},
				view = {
					format = self.color_format,
					aspect = "color",
				},
				sampler = false,
			}
		)
		self.textures = {texture}
		return
	end

	-- Windowed mode: recreate swapchain
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
	local textures = {}

	for i, img in ipairs(self.swapchain:GetImages()) do
		textures[i] = Texture.New(
			{
				image = img,
				view = {format = self.surface_format.format},
				sampler = false,
			}
		)
	end

	self.textures = textures
end

local function create_depth_buffer(self)
	local extent = self.config.offscreen and self.extent or self.surface_capabilities.currentExtent
	self.depth_texture = Texture.New(
		{
			width = extent.width,
			height = extent.height,
			format = self.depth_format,
			buffer = false,
			image = {
				width = extent.width,
				height = extent.height,
				format = self.depth_format,
				usage = {"depth_stencil_attachment"},
				properties = "device_local",
				samples = self.samples,
			},
			view = {
				format = self.depth_format,
				aspect = "depth",
			},
			sampler = false,
		}
	)
end

local function create_msaa_buffer(self)
	local extent = self.config.offscreen and self.extent or self.surface_capabilities.currentExtent

	-- Recreate MSAA color buffer if using MSAA
	if self.samples ~= "1" then
		local format = self.config.offscreen and self.color_format or self.surface_format.format
		self.msaa_image = Texture.New(
			{
				width = extent.width,
				height = extent.height,
				format = format,
				buffer = false,
				image = {
					width = extent.width,
					height = extent.height,
					format = format,
					usage = {"color_attachment"},
					properties = "device_local",
					samples = self.samples,
				},
				view = {format = format},
				sampler = false,
			}
		)
	end
end

local function create_per_frame_resources(self)
	if self.config.offscreen then
		-- Offscreen mode: only need one command buffer
		if self.command_buffers and #self.command_buffers == 1 then return end

		self.command_buffers = {}
		self.command_buffers[1] = self.vulkan_instance.command_pool:AllocateCommandBuffer()
		return
	end

	-- Windowed mode: need resources per swapchain image
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

function ImageRenderTarget.New(vulkan_instance, config)
	config = config or {}

	for k, v in pairs(default_config) do
		if config[k] == nil then config[k] = v end
	end

	if config.width == 0 then config.width = 512 end

	if config.height == 0 then config.height = 512 end

	local self = setmetatable({config = config}, ImageRenderTarget)
	self.vulkan_instance = vulkan_instance
	self.current_frame = 0
	self.texture_index = 1
	choose_format(self)
	create_swapchain(self)
	create_depth_buffer(self)
	create_msaa_buffer(self)
	create_per_frame_resources(self)

	-- For backward compatibility with offscreen mode, expose image field
	if config.offscreen then self.image = self:GetImage() end

	return self
end

function ImageRenderTarget:GetImage()
	return self.textures[self.texture_index]:GetImage()
end

function ImageRenderTarget:GetTexture()
	return self.textures[self.texture_index]
end

function ImageRenderTarget:GetColorFormat()
	return self.color_format
end

function ImageRenderTarget:GetDepthFormat()
	return self.depth_format
end

function ImageRenderTarget:GetSamples()
	return self.samples
end

function ImageRenderTarget:GetImageView()
	return self.textures[self.texture_index]:GetView()
end

function ImageRenderTarget:GetMSAAImageView()
	return self.msaa_image:GetView()
end

function ImageRenderTarget:GetDepthImageView()
	return self.depth_texture:GetView()
end

function ImageRenderTarget:WaitForPreviousFrame()
	-- Wait for the next frame's fence (which is the one we'll use next)
	-- This ensures previous frame work is complete before we start new work
	-- Don't reset the fence - BeginFrame will do that
	local next_frame = (self.current_frame % #self.textures) + 1

	if self.in_flight_fences and self.in_flight_fences[next_frame] then
		self.in_flight_fences[next_frame]:Wait(true) -- skip_reset = true
	end
end

function ImageRenderTarget:BeginFrame()
	self.current_frame = (self.current_frame % #self.textures) + 1

	if self.in_flight_fences and self.in_flight_fences[self.current_frame] then
		self.in_flight_fences[self.current_frame]:Wait()
	end

	if self.swapchain then
		local texture_index = self.swapchain:GetNextImage(self.image_available_semaphores[self.current_frame])

		if texture_index == nil then
			self:RebuildFramebuffers()
			return nil
		end

		self.texture_index = texture_index + 1
	else
		self.texture_index = 1
	end

	local cmd = self:GetCommandBuffer()
	cmd:Reset()
	cmd:Begin()
	local imageBarriers = {
		{
			image = self:GetImage(),
			srcAccessMask = "none",
			dstAccessMask = "color_attachment_write",
			oldLayout = "undefined",
			newLayout = "color_attachment_optimal",
		},
	}

	-- Add depth barrier for offscreen mode
	if self.config.offscreen then
		table.insert(
			imageBarriers,
			{
				image = self.depth_texture:GetImage(),
				srcAccessMask = "none",
				dstAccessMask = "depth_stencil_attachment_write",
				oldLayout = "undefined",
				newLayout = "depth_attachment_optimal",
				aspect = "depth",
			}
		)
	end

	cmd:PipelineBarrier(
		{
			srcStage = self.config.offscreen and "top_of_pipe" or "color_attachment_output",
			dstStage = self.config.offscreen and "early_fragment_tests" or "color_attachment_output",
			imageBarriers = imageBarriers,
		}
	)
	local extent = self:GetExtent()
	event.Call("PreRenderPass", cmd)
	local render_config = {
		color_image_view = self:GetImageView(),
		w = extent.width,
		h = extent.height,
		clear_color = self.config.offscreen and {0.0, 0.0, 0.0, 1.0} or {0.2, 0.2, 0.2, 1.0},
	}
	-- Add depth buffer for both offscreen and windowed modes
	render_config.depth_image_view = self:GetDepthImageView()
	render_config.clear_depth = 1.0

	-- Add MSAA for windowed mode only
	if not self.config.offscreen then
		render_config.msaa_image_view = self:GetMSAAImageView()
	end

	cmd:BeginRendering(render_config)
	-- Set viewport and scissor
	cmd:SetViewport(0, 0, extent.width, extent.height, 0, 1)
	cmd:SetScissor(0, 0, extent.width, extent.height)
	return cmd
end

function ImageRenderTarget:EndFrame()
	local command_buffer = self.command_buffers[self.current_frame]
	-- End rendering pass
	command_buffer:EndRendering()
	-- Copy query results after render pass ends (windowed mode only)
	event.Call("PostRenderPass", command_buffer)
	-- Transition image to final layout
	local final_layout = self.config.offscreen and self.final_layout or "present_src_khr"
	local dst_stage = self.config.offscreen and "transfer" or "color_attachment_output"
	local dst_access = self.config.offscreen and "transfer_read" or "none"
	command_buffer:PipelineBarrier(
		{
			srcStage = "color_attachment_output",
			dstStage = dst_stage,
			imageBarriers = {
				{
					image = self:GetImage(),
					srcAccessMask = "color_attachment_write",
					dstAccessMask = dst_access,
					oldLayout = "color_attachment_optimal",
					newLayout = final_layout,
				},
			},
		}
	)
	command_buffer:End()

	-- Submit command buffer
	if self.config.offscreen then
		-- Offscreen: simple submit and wait
		local fence = Fence.New(self.vulkan_instance.device)
		self.vulkan_instance.queue:SubmitAndWait(self.vulkan_instance.device, command_buffer, fence)
	else
		-- Windowed: submit with semaphores
		-- Use current_frame for image_available (wait) semaphore and fence
		-- Use texture_index for render_finished (signal) semaphore
		self.vulkan_instance.queue:Submit(
			command_buffer,
			self.image_available_semaphores[self.current_frame],
			self.render_finished_semaphores[self.texture_index],
			self.in_flight_fences[self.current_frame]
		)

		-- Present and recreate swapchain if needed
		if
			not self.swapchain:Present(
				self.render_finished_semaphores[self.texture_index],
				self.vulkan_instance.queue,
				ffi.new("uint32_t[1]", self.texture_index - 1)
			)
		then
			self:RebuildFramebuffers()
		end
	end
end

function ImageRenderTarget:RebuildFramebuffers()
	if self.config.offscreen then
		-- Offscreen mode doesn't need rebuilding
		return
	end

	-- Wait for device to be idle
	self.vulkan_instance.device:WaitIdle()
	choose_format(self)
	create_swapchain(self)
	create_depth_buffer(self)
	create_msaa_buffer(self)
	create_per_frame_resources(self)
end

function ImageRenderTarget:GetCommandBuffer()
	return self.command_buffers[self.current_frame]
end

function ImageRenderTarget:GetCurrentFrame()
	return self.current_frame
end

function ImageRenderTarget:GetExtent()
	if self.config.offscreen then return self.extent end

	return self.surface_capabilities.currentExtent
end

function ImageRenderTarget:GetSwapchainImageCount()
	return #self.textures
end

-- Additional methods for offscreen mode compatibility
function ImageRenderTarget:WriteMode(cmd)
	if not self.config.offscreen then
		return -- Only applicable in offscreen mode
	end

	cmd:PipelineBarrier(
		{
			srcStage = "fragment",
			dstStage = "all_commands",
			imageBarriers = {
				{
					image = self:GetImage(),
					srcAccessMask = "shader_read",
					dstAccessMask = "color_attachment_write",
					oldLayout = "shader_read_only_optimal",
					newLayout = "color_attachment_optimal",
				},
			},
		}
	)
end

function ImageRenderTarget:ReadMode(cmd)
	if not self.config.offscreen then
		return -- Only applicable in offscreen mode
	end

	cmd:PipelineBarrier(
		{
			srcStage = "all_commands",
			dstStage = "fragment",
			imageBarriers = {
				{
					image = self:GetImage(),
					srcAccessMask = "color_attachment_write",
					dstAccessMask = "shader_read",
					oldLayout = "color_attachment_optimal",
					newLayout = "shader_read_only_optimal",
				},
			},
		}
	)
end

return ImageRenderTarget
