local ffi = require("ffi")
local render = {}
local renderdoc = require("bindings.renderdoc")

if pcall(renderdoc.init) then render.renderdoc = renderdoc end

local VulkanInstance = require("graphics.vulkan.vulkan_instance")
local event = require("event")
local system = require("system")
local Image = require("graphics.vulkan.internal.image")
local Sampler = require("graphics.vulkan.internal.sampler")
local Vec2 = require("structs.vec2")
local vulkan_instance

function render.Initialize(config)

	if render.target then return end

	config = config or {}
	local is_headless = config.headless

	if not is_headless then
		-- Windowed mode: create window and surface
		local window = require("graphics.window")
		local surface_handle, display_handle = assert(window:GetSurfaceHandle())
		vulkan_instance = VulkanInstance.New(surface_handle, display_handle)
		local size = window:GetSize()
		local target = vulkan_instance:CreateWindowRenderTarget(
			{
				present_mode = "immediate_khr", --"fifo_khr",
				image_count = nil, -- Use default (minImageCount + 1)
				surface_format_index = 1,
				composite_alpha = "opaque_khr",
				width = size.x,
				height = size.y,
			}
		)
		render.target = target
	else
		vulkan_instance = VulkanInstance.New(nil, nil)
		local width = config.width or 512
		local height = config.height or 512
		local target = vulkan_instance:CreateWindowRenderTarget(
			{
				offscreen = true,
				width = width,
				height = height,
				format = "r8g8b8a8_unorm",
				usage = {"color_attachment", "transfer_src"},
				samples = "1",
				final_layout = "transfer_src_optimal",
			}
		)
		render.target = target
	end

	function events.WindowFramebufferResized.window_resized(wnd, size)
		render.target.config.width = size.x
		render.target.config.height = size.y
		render.target:RebuildFramebuffers()
	end

	function events.Update.window_update(dt)
		-- Shadow passes run before main frame (before swapchain acquire)
		event.Call("PreFrame", dt)
		render.BeginFrame()
		event.Call("Draw", render.GetCommandBuffer(), dt)
		event.Call("PostDraw", render.GetCommandBuffer(), dt)
		render.EndFrame()
	end

	function events.ShutDown.window_shutdown()
		vulkan_instance.device:WaitIdle()
	end
end

function render.BeginFrame()
	render.cmd = render.target:BeginFrame()
end

function render.GetCommandBuffer()
	return render.cmd
end

function render.EndFrame()
	render.target:EndFrame()
end

function render.GetRenderImageSize()
	return Vec2(render.target.config.width, render.target.config.height)
end

function render.CreateBuffer(config)
	return vulkan_instance:CreateBuffer(config)
end

function render.CreateOcclusionQuery()
	return vulkan_instance:CreateOcclusionQuery()
end

function render.CreateImage(config)
	config.device = vulkan_instance.device
	return Image.New(config)
end

function render.CreateSampler(config)
	config.device = vulkan_instance.device
	return Sampler.New(config)
end

function render.CreateGraphicsPipeline(config)
	if config.color_format == nil and config.color_format ~= false then
		config.color_format = render.target:GetColorFormat()
	elseif config.color_format == false then
		config.color_format = nil
	end

	config.depth_format = config.depth_format or render.target:GetDepthFormat()
	config.samples = config.samples or render.target:GetSamples()
	config.descriptor_set_count = config.descriptor_set_count or render.target:GetSwapchainImageCount()
	return vulkan_instance:CreateGraphicsPipeline(config)
end

function render.CreateComputePipeline(config)
	return vulkan_instance:CreateComputePipeline(config)
end

function render.GetDevice()
	return vulkan_instance.device
end

function render.GetQueue()
	return vulkan_instance.queue
end

function render.GetCommandPool()
	return vulkan_instance.command_pool
end

function render.GetCurrentFrame()
	return render.target:GetCurrentFrame()
end

function render.GetSwapchainImageCount()
	return render.target:GetSwapchainImageCount()
end

function render.CreateCommandBuffer()
	return vulkan_instance.command_pool:AllocateCommandBuffer()
end

function render.CopyImageToCPU(image, width, height, format, current_layout)
	format = format or "r8g8b8a8_unorm"
	current_layout = current_layout or "transfer_src_optimal"
	local bytes_per_pixel = 4 -- Assume RGBA for now
	local Buffer = require("graphics.vulkan.internal.buffer")
	local Fence = require("graphics.vulkan.internal.fence")
	-- Create staging buffer
	local staging_buffer = Buffer.New(
		{
			device = vulkan_instance.device,
			size = width * height * bytes_per_pixel,
			usage = "transfer_dst",
			properties = {"host_visible", "host_coherent"},
		}
	)
	-- Create command buffer for copy
	local copy_cmd = vulkan_instance.command_pool:AllocateCommandBuffer()
	copy_cmd:Begin()
	local vulkan = require("graphics.vulkan.internal.vulkan")
	vulkan.lib.vkCmdCopyImageToBuffer(
		copy_cmd.ptr[0],
		image.ptr[0],
		vulkan.vk.e.VkImageLayout(current_layout),
		staging_buffer.ptr[0],
		1,
		vulkan.vk.VkBufferImageCopy(
			{
				bufferOffset = 0,
				bufferRowLength = 0,
				bufferImageHeight = 0,
				imageSubresource = vulkan.vk.s.ImageSubresourceLayers(
					{
						aspectMask = "color",
						mipLevel = 0,
						baseArrayLayer = 0,
						layerCount = 1,
					}
				),
				imageOffset = vulkan.vk.VkOffset3D({x = 0, y = 0, z = 0}),
				imageExtent = vulkan.vk.VkExtent3D({width = width, height = height, depth = 1}),
			}
		)
	)
	copy_cmd:End()
	-- Submit and wait
	local fence = Fence.New(vulkan_instance.device)
	vulkan_instance.queue:SubmitAndWait(vulkan_instance.device, copy_cmd, fence)
	-- Map staging buffer and copy pixel data
	local pixel_data = staging_buffer:Map()
	local pixels = ffi.new("uint8_t[?]", width * height * bytes_per_pixel)
	ffi.copy(pixels, pixel_data, width * height * bytes_per_pixel)
	staging_buffer:Unmap()
	return {
		pixels = pixels,
		width = width,
		height = height,
		format = format,
		bytes_per_pixel = bytes_per_pixel,
		size = width * height * bytes_per_pixel,
	}
end

return render
