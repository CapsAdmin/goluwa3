local ffi = require("ffi")
local render = {}
--local renderdoc = require("bindings.renderdoc")
--if pcall(renderdoc.init) then render.renderdoc = renderdoc end
-- Check if shaderc is available before loading Vulkan
local shaderc = require("bindings.shaderc")

if not shaderc.available then
	logf("[render] WARNING: shaderc library not found - render will not be initialized\n")
	logf("[render] %s\n", shaderc.error_message)
	logf("[render] Running in headless mode without graphics. REPL will be available.\n")
	logf(
		"[render] To enable graphics, install the Vulkan SDK from: https://vulkan.lunarg.com/\n"
	)
	render.available = false
	return render
end

render.available = true
local VulkanInstance = require("render.vulkan.vulkan_instance")
local event = require("event")
local system = require("system")
local Image = require("render.vulkan.internal.image")
local Sampler = require("render.vulkan.internal.sampler")
local Vec2 = require("structs.vec2")
local vulkan_instance

function render.Initialize(config)
	if render.target then
		render.GetDevice():WaitIdle()
		return
	end

	config = config or {}
	local is_headless = config.headless

	if not is_headless then
		-- Windowed mode: create window and surface
		local window = require("render.window")
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

	event.AddListener("WindowFramebufferResized", "window_resized", function(wnd, size)
		render.target.config.width = size.x
		render.target.config.height = size.y
		render.target:RebuildFramebuffers()
	end)

	event.AddListener("Update", "window_update", function(dt)
		-- Wait for previous frame before starting shadow passes
		render.target:WaitForPreviousFrame()
		-- Shadow passes run before main frame (before swapchain acquire)
		event.Call("PreFrame", dt)
		render.BeginFrame()
		event.Call("Draw", render.GetCommandBuffer(), dt)
		event.Call("PostDraw", render.GetCommandBuffer(), dt)
		render.EndFrame()
	end)

	event.AddListener("ShutDown", "window_shutdown", function()
		vulkan_instance.device:WaitIdle()
	end)
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

	if config.depth_format == nil and config.depth_format ~= false then
		config.depth_format = render.target:GetDepthFormat()
	elseif config.depth_format == false then
		config.depth_format = nil
	end

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

do
	local png = require("codecs.png")
	local fs = require("fs")

	function render.Screenshot(name)
		local width, height = render.GetRenderImageSize():Unpack()
		local image_data = render.target:GetTexture():Download()
		local png = png.Encode(width, height, "rgba")
		local pixel_table = {}

		for i = 0, image_data.size - 1 do
			pixel_table[i + 1] = image_data.pixels[i]
		end

		png:write(pixel_table)
		local screenshot_dir = "./logs/screenshots"
		fs.create_directory_recursive(screenshot_dir)
		local screenshot_path = screenshot_dir .. "/" .. name .. ".png"
		local file = assert(io.open(screenshot_path, "wb"))
		file:write(png:getData())
		file:close()
		return screenshot_path
	end
end

local formats = {
	r8g8b8a8_unorm = (8 + 8 + 8 + 8) / 8,
	r8g8b8a8_srgb = (8 + 8 + 8 + 8) / 8,
	b8g8r8a8_unorm = (8 + 8 + 8 + 8) / 8,
	b8g8r8a8_srgb = (8 + 8 + 8 + 8) / 8,
	b8g8r8a8_unorm = (8 + 8 + 8 + 8) / 8,
	b8g8r8a8_srgb = (8 + 8 + 8 + 8) / 8,
	r16g16b16a16_sfloat = (16 + 16 + 16 + 16) / 8,
	r32g32b32a32_sfloat = (32 + 32 + 32 + 32) / 8,
	r32g32b32_sfloat = (32 + 32 + 32) / 8,
	r32g32_sfloat = (32 + 32) / 8,
}

function render.GetVulkanFormatSize(format)
	if not formats[format] then error("unknown format: " .. tostring(format)) end

	return formats[format]
end

function render.TriggerValidationError()
	local vulkan = require("render.vulkan.internal.vulkan")
	local create_info = vulkan.vk.VkBufferCreateInfo(
		{
			sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO + 10, -- INVALID STYPE,
			pNext = nil,
			flags = 1110, -- INVALID FLAGS
			size = 0, -- INVALID SIZE
			usage = vulkan.vk.VkBufferUsageFlagBits.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
			sharingMode = vulkan.vk.VkSharingMode.VK_SHARING_MODE_EXCLUSIVE,
			queueFamilyIndexCount = 0,
			pQueueFamilyIndices = nil,
		}
	)
	local buffer = ffi.new("void*[1]")
	assert(
		vulkan.lib.vkCreateBuffer(assert(vulkan_instance.device.ptr[0]), create_info, nil, buffer) ~= 0
	)
end

return render
