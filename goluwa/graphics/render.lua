local VulkanInstance = require("graphics.vulkan.vulkan_instance")
local window = require("graphics.window")
local event = require("event")
local ffi = require("ffi")
local system = require("system")
local Image = require("graphics.vulkan.internal.image")
local Sampler = require("graphics.vulkan.internal.sampler")
local surface_handle, display_handle = assert(window:GetSurfaceHandle())
local vulkan_instance = VulkanInstance.New(surface_handle, display_handle)
local size = window:GetSize()
local window_target = vulkan_instance:CreateWindowRenderTarget(
	{
		present_mode = "fifo",
		image_count = nil, -- Use default (minImageCount + 1)
		surface_format_index = 1,
		composite_alpha = "opaque",
		width = size.x,
		height = size.y,
	}
)

event.AddListener("WindowFramebufferResized", "window_resized", function(wnd, size)
	window_target.config.width = size.x
	window_target.config.height = size.y
	window_target:RebuildFramebuffers()
end)

event.AddListener("Update", "window_update", function(dt)
	if not window_target:BeginFrame() then return end

	window_target:BeginCommandBuffer()
	local cmd = window_target:GetCommandBuffer()
	-- Transition swapchain image to color attachment optimal
	cmd:PipelineBarrier(
		{
			srcStage = "color_attachment_output",
			dstStage = "color_attachment_output",
			imageBarriers = {
				{
					image = window_target:GetSwapChainImage(),
					srcAccessMask = "none",
					dstAccessMask = "color_attachment_write",
					oldLayout = "undefined",
					newLayout = "color_attachment_optimal",
				},
			},
		}
	)
	cmd:BeginRendering(
		{
			colorImageView = window_target:GetImageView(),
			msaaImageView = window_target:GetMSAAImageView(),
			depthImageView = window_target:GetDepthImageView(),
			extent = window_target:GetExtent(),
			clearColor = {0.2, 0.2, 0.2, 1.0},
			clearDepth = 1.0,
		}
	)
	local extent = window_target:GetExtent()
	local aspect = extent.width / extent.height
	cmd:SetViewport(0.0, 0.0, extent.width, extent.height, 0.0, 1.0)
	cmd:SetScissor(0, 0, extent.width, extent.height)
	event.Call("Draw", cmd, dt)
	event.Call("PostDraw", cmd, dt)
	cmd:EndRendering()
	-- Transition swapchain image to present src
	cmd:PipelineBarrier(
		{
			srcStage = "color_attachment_output",
			dstStage = "color_attachment_output",
			imageBarriers = {
				{
					image = window_target:GetSwapChainImage(),
					srcAccessMask = "color_attachment_write",
					dstAccessMask = "none",
					oldLayout = "color_attachment_optimal",
					newLayout = "present_src_khr",
				},
			},
		}
	)
	window_target:EndFrame()
end)

event.AddListener("ShutDown", "window_shutdown", function()
	vulkan_instance.device:WaitIdle()
end)

local render = {}

function render.VertexDataToIndices(val)
	local tbl

	if type(val) == "number" then
		tbl = {}

		for i = 1, val do
			tbl[i] = i - 1
		end
	elseif type(val[1]) == "table" then
		tbl = {}

		for i in ipairs(val) do
			tbl[i] = i - 1
		end
	else
		tbl = val
		local max = 0

		for _, i in ipairs(val) do
			max = math.max(max, i)
		end
	end

	return tbl
end

function render.CreateBuffer(config)
	return vulkan_instance:CreateBuffer(config)
end

function render.CreateImage(config)
	config.device = vulkan_instance.device
	return Image.New(config)
end

function render.CreateSampler(config)
	return Sampler.New(vulkan_instance.device, config)
end

function render.CreateGraphicsPipeline(config)
	config.color_format = config.color_format or window_target:GetColorFormat()
	config.depth_format = config.depth_format or window_target:GetDepthFormat()
	config.samples = config.samples or window_target:GetSamples()
	config.descriptor_set_count = config.descriptor_set_count or window_target:GetSwapchainImageCount()
	return vulkan_instance:CreateGraphicsPipeline(config)
end

function render.CreateOffscreenRenderTarget(config)
	return vulkan_instance:CreateOffscreenRenderTarget(config)
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
	return window_target:GetCurrentFrame()
end

function render.GetSwapchainImageCount()
	return window_target:GetSwapchainImageCount()
end

return render
