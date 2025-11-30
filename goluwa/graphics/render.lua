local ffi = require("ffi")
local render = {}
local renderdoc = require("bindings.renderdoc")

if pcall(renderdoc.init) then render.renderdoc = renderdoc end

local VulkanInstance = require("graphics.vulkan.vulkan_instance")
local window = require("graphics.window")
local event = require("event")
local system = require("system")
local Image = require("graphics.vulkan.internal.image")
local Sampler = require("graphics.vulkan.internal.sampler")
local vulkan_instance

function render.Initialize()
	local surface_handle, display_handle = assert(window:GetSurfaceHandle())
	vulkan_instance = VulkanInstance.New(surface_handle, display_handle)
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
	render.window_target = window_target

	event.AddListener("WindowFramebufferResized", "window_resized", function(wnd, size)
		window_target.config.width = size.x
		window_target.config.height = size.y
		window_target:RebuildFramebuffers()
	end)

	event.AddListener("Update", "window_update", function(dt)
		-- Shadow passes run before main frame (before swapchain acquire)
		event.Call("PreFrame", dt)
		local cmd = window_target:BeginFrame()

		if not cmd then return end

		event.Call("Draw", cmd, dt)
		event.Call("PostDraw", cmd, dt)
		window_target:EndFrame()
	end)

	event.AddListener("ShutDown", "window_shutdown", function()
		vulkan_instance.device:WaitIdle()
	end)
end

function render.CreateBuffer(config)
	return vulkan_instance:CreateBuffer(config)
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
	-- Only set defaults if not explicitly provided (nil check allows explicit nil for depth-only)
	if config.color_format == nil and config.color_format ~= false then
		config.color_format = render.window_target:GetColorFormat()
	elseif config.color_format == false then
		config.color_format = nil
	end

	config.depth_format = config.depth_format or render.window_target:GetDepthFormat()
	config.samples = config.samples or render.window_target:GetSamples()
	config.descriptor_set_count = config.descriptor_set_count or render.window_target:GetSwapchainImageCount()
	return vulkan_instance:CreateGraphicsPipeline(config)
end

function render.CreateComputePipeline(config)
	return vulkan_instance:CreateComputePipeline(config)
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
	return render.window_target:GetCurrentFrame()
end

function render.GetSwapchainImageCount()
	return render.window_target:GetSwapchainImageCount()
end

function render.CreateCommandBuffer()
	return vulkan_instance.command_pool:AllocateCommandBuffer()
end

return render
