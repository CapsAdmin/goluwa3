local VulkanInstance = require("graphics.vulkan.vulkan_instance")
local window = require("graphics.window")
local event = require("event")
local ffi = require("ffi")
local system = require("system")
local Image = require("graphics.vulkan.internal.image")
local Sampler = require("graphics.vulkan.internal.sampler")
local surface = assert(window:GetSurfaceHandle())
local vulkan_instance = VulkanInstance.New(surface)
local window_target = vulkan_instance:CreateWindowRenderTarget(
	{
		present_mode = "fifo",
		image_count = nil, -- Use default (minImageCount + 1)
		surface_format_index = 1,
		composite_alpha = "opaque",
	}
)

event.AddListener("WindowFramebufferResized", "window_resized", function(wnd, size)
	window_target:RebuildFramebuffers()
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
	config.render_pass = config.render_pass or window_target:GetRenderPass()
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
