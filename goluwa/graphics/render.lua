local VulkanInstance = require("graphics.vulkan.instance")
local window = require("graphics.window")
local event = require("event")
local ffi = require("ffi")
local system = require("system")
local Image = require("graphics.vulkan.internal.image")
local Sampler = require("graphics.vulkan.internal.sampler")
local vulkan_instance = VulkanInstance.New(
	{
		surface_handle = assert(window:GetSurfaceHandle()),
		present_mode = "fifo",
		image_count = nil, -- Use default (minImageCount + 1)
		surface_format_index = 1,
		composite_alpha = "opaque",
	}
)
local window_target = vulkan_instance:CreateWindowRenderTarget()

event.AddListener("FramebufferResized", "window_resized", function(size)
	window_target:RecreateSwapchain()
end)

event.AddListener("Update", "window_update", function(dt)
	if not window_target:BeginFrame() then return end

	window_target:BeginCommandBuffer()
	local cmd = window_target:GetCommandBuffer()
	cmd:BeginRenderPass(
		window_target:GetRenderPass(),
		window_target:GetFramebuffer(),
		window_target:GetExtent(),
		{0.2, 0.2, 0.2, 1.0}
	)
	local extent = window_target:GetExtent()
	local aspect = extent.width / extent.height
	cmd:SetViewport(0.0, 0.0, extent.width, extent.height, 0.0, 1.0)
	cmd:SetScissor(0, 0, extent.width, extent.height)
	event.Call("Draw", cmd, dt)
	event.Call("PostDraw", cmd, dt)
	cmd:EndRenderPass()
	window_target:EndFrame()
end)

event.AddListener("Shutdown", "window_shutdown", function()
	vulkan_instance:WaitForIdle()
	system.ShutDown()
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

function render.CreateImage(width, height, format, usage, memory_properties, samples, mip_levels)
	return Image.New(
		{
			device = vulkan_instance.device,
			width = width,
			height = height,
			format = format,
			usage = usage,
			properties = memory_properties,
			samples = samples,
			mip_levels = mip_levels,
		}
	)
end

function render.UploadToImage(image, data, width, height, keep_in_transfer_dst)
	return vulkan_instance:UploadToImage(image, data, width, height, keep_in_transfer_dst)
end

function render.CreateSampler(config)
	return Sampler.New(vulkan_instance.device, config)
end

function render.CreateGraphicsPipeline(config)
	config.render_pass = config.render_pass or window_target:GetRenderPass()
	return vulkan_instance:CreateGraphicsPipeline(config)
end

function render.CreateOffscreenRenderTarget(width, height, format, config)
	return vulkan_instance:CreateOffscreenRenderTarget(width, height, format, config)
end

function render.CreateIndexBuffer()
	local IndexBuffer = require("graphics.index_buffer")
	return IndexBuffer.New()
end

function render.GetDevice()
	return vulkan_instance.device
end

function render.GetQueue()
	return vulkan_instance.queue
end

function render.GetGraphicsQueueFamily()
	return vulkan_instance.graphics_queue_family
end

function render.GetCurrentFrame()
	return window_target:GetCurrentFrame()
end

function render.GetSwapchainImageCount()
	return #vulkan_instance.swapchain_images
end

return render
