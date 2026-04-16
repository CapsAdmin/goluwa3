local ffi = require("ffi")
local render = {}
import.loaded["goluwa/render/render.lua"] = render
--local renderdoc = import("goluwa/bindings/renderdoc.lua")
--if pcall(renderdoc.init) then render.renderdoc = renderdoc end
-- Check if shaderc is available before loading Vulkan
local shaderc = import("goluwa/bindings/shaderc.lua")

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
local VulkanInstance = import("goluwa/render/vulkan/vulkan_instance.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Image = import("goluwa/render/vulkan/internal/image.lua")
local Sampler = import("goluwa/render/vulkan/internal/sampler.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Texture = import("goluwa/render/texture.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local Fence = import("goluwa/render/vulkan/internal/fence.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local vulkan_instance
local sync_fence = NULL
render.command_buffer_stack = render.command_buffer_stack or {}
render.target = render.target or NULL

function render.Shutdown()
	if render.shutting_down then return end

	render.shutting_down = true
	event.RemoveListener("WindowFramebufferResized", "window_resized")
	event.RemoveListener("Update", "window_update")

	if render.target:IsValid() then render.target:Remove() end

	if vulkan_instance:IsValid() then vulkan_instance:Remove() end

	render.command_buffer_stack = {}
	render.cmd = NULL
	render.in_frame = false
	render.target = NULL
	vulkan_instance = NULL
	render.cached_samplers = {}
	sync_fence = NULL
	render.shutting_down = false
end

function render.Initialize(config)
	config = config or {}
	local is_headless = config.headless

	if not is_headless then
		-- Windowed mode: create window and surface
		local wnd = assert(
			system.GetWindow(),
			"render.Initialize() requires a window; call system.OpenWindow() first"
		)
		local surface_handle, display_handle = assert(wnd:GetSurfaceHandle())
		vulkan_instance = VulkanInstance.New(surface_handle, display_handle)
		local size = wnd:GetSize()
		render.target = vulkan_instance:CreateWindowRenderTarget{
			present_mode = "immediate_khr", --"fifo_khr",
			image_count = nil, -- Use default (minImageCount + 1)
			--surface_format_index = 1,
			composite_alpha = "opaque_khr",
			width = size.x,
			height = size.y,
			samples = config.samples,
		}
	else
		vulkan_instance = VulkanInstance.New(nil, nil)
		local width = config.width or 512
		local height = config.height or 512
		render.target = vulkan_instance:CreateWindowRenderTarget{
			offscreen = true,
			width = width,
			height = height,
			format = "r8g8b8a8_unorm",
			usage = {"color_attachment", "transfer_src"},
			samples = "1",
			final_layout = "transfer_src_optimal",
		}
	end

	event.Call("RendererReady")

	event.AddListener("WindowFramebufferResized", "window_resized", function(wnd, size)
		if is_headless then return end

		render.target.config.width = size.x
		render.target.config.height = size.y
		render.target:RebuildFramebuffers()
	end)

	event.AddListener("Shutdown", "render_shutdown", function()
		render.Shutdown()
	end)

	function render.Draw(dt)
		if render.in_frame then return end

		-- Wait for previous frame before starting shadow passes
		render.target:WaitForPreviousFrame()
		-- Shadow passes run before main frame (before swapchain acquire)
		event.Call("PreFrame", dt)

		if render.BeginFrame() then
			event.Call("Draw", dt)
			event.Call("PostDraw", dt)
			render.EndFrame()
		end
	end

	event.AddListener("Update", "window_update", render.Draw)
end

function render.BeginFrame()
	render.cmd = render.target:BeginFrame()

	if render.cmd then render.in_frame = true end

	return render.GetCommandBuffer()
end

function render.SetCommandBuffer(cmd)
	local stack = render.command_buffer_stack

	if #stack > 0 then
		local previous = stack[#stack]
		stack[#stack] = cmd
		return previous
	end

	local previous = render.cmd
	render.cmd = cmd
	return previous
end

function render.PushCommandBuffer(cmd)
	render.command_buffer_stack[#render.command_buffer_stack + 1] = cmd
	return cmd
end

function render.PopCommandBuffer()
	local stack = render.command_buffer_stack

	if #stack == 0 then error("render command buffer stack underflow", 2) end

	return table.remove(stack)
end

function render.GetCommandBuffer()
	local stack = render.command_buffer_stack
	return stack[#stack] or render.cmd
end

function render.GetCommandBufferOutsideRendering()
	local cmd = render.GetCommandBuffer()

	if cmd and cmd.is_rendering then return nil end

	return cmd
end

function render.KeepCommandBufferResource(resource, cmd)
	cmd = cmd or render.GetCommandBuffer()

	if not cmd then return resource end

	cmd.keepalive_resources = cmd.keepalive_resources or {}
	table.insert(cmd.keepalive_resources, resource)
	return resource
end

function render.EndFrame()
	if not render.in_frame then return end

	render.target:EndFrame()
	render.command_buffer_stack = {}
	render.cmd = nil
	render.in_frame = false
end

function render.GetRenderImageSize()
	return Vec2(render.target.config.width, render.target.config.height)
end

function render.CreateBuffer(config)
	return vulkan_instance:CreateBuffer(config)
end

function render.GetErrorTexture()
	if not vulkan_instance or vulkan_instance == NULL or not vulkan_instance.device then
		return nil
	end

	return Texture.GetFallback()
end

function render.CreateFrameBuffer(size, config)
	config = config or {}

	if size then
		config.width = config.width or size.x or size.w
		config.height = config.height or size.y or size.h
	end

	config.width = math.floor(tonumber(config.width) or 0)
	config.height = math.floor(tonumber(config.height) or 0)

	if config.width <= 0 or config.height <= 0 then
		error(
			(
				"render.CreateFrameBuffer: invalid size %sx%s"
			):format(tostring(config.width), tostring(config.height)),
			2
		)
	end

	if config.min_filter == nil and config.mag_filter ~= nil then
		config.min_filter = config.mag_filter
	end

	if config.mag_filter == nil and config.min_filter ~= nil then
		config.mag_filter = config.min_filter
	end

	return Framebuffer.New(config)
end

function render.CreateOcclusionQuery()
	return vulkan_instance:CreateOcclusionQuery()
end

function render.CreateImage(config)
	if
		not config or
		type(config.format) ~= "string" or
		config.format == "" or
		config.format == "undefined"
	then
		error("render.CreateImage: invalid format " .. tostring(config and config.format), 2)
	end

	config.device = vulkan_instance.device
	return Image.New(config)
end

do
	render.cached_samplers = {}

	function render.CreateSampler(config)
		local hash = table.hash(config)

		if render.cached_samplers[hash] then return render.cached_samplers[hash] end

		config.device = vulkan_instance.device
		local sampler = Sampler.New(config)
		render.cached_samplers[hash] = sampler
		return sampler
	end
end

local function assert_no_legacy_graphics_pipeline_fields(config)
	for _, field_name in ipairs{
		"color_format",
		"depth_format",
		"samples",
		"rasterization_samples",
		"descriptor_set_count",
		"static",
	} do
		if config[field_name] ~= nil then
			error(
				string.format(
					"render.CreateGraphicsPipeline: use PascalCase %s instead of snake_case %s",
					(
						{
							color_format = "ColorFormat",
							depth_format = "DepthFormat",
							samples = "RasterizationSamples",
							rasterization_samples = "RasterizationSamples",
							descriptor_set_count = "DescriptorSetCount",
							static = "Static",
						}
					)[field_name],
					field_name
				),
				2
			)
		end
	end

	if config.Samples ~= nil then
		error("render.CreateGraphicsPipeline: use RasterizationSamples instead of Samples", 2)
	end

	if
		config.dynamic_state ~= nil or
		config.dynamic_states ~= nil or
		config.DynamicStates ~= nil
	then
		error("render.CreateGraphicsPipeline: dynamic state is handled internally", 2)
	end
end

function render.CreateGraphicsPipeline(config)
	assert_no_legacy_graphics_pipeline_fields(config)

	if config.ColorFormat == nil and config.ColorFormat ~= false then
		config.ColorFormat = render.target:GetColorFormat()
	elseif config.ColorFormat == false then
		config.ColorFormat = nil
	end

	if config.DepthFormat == nil and config.DepthFormat ~= false then
		config.DepthFormat = render.target:GetDepthFormat()
	elseif config.DepthFormat == false then
		config.DepthFormat = nil
	end

	config.RasterizationSamples = config.RasterizationSamples or render.target:GetSamples()
	config.DescriptorSetCount = config.DescriptorSetCount or render.target:GetSwapchainImageCount()
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

function render.GetSyncFence()
	if not sync_fence:IsValid() then sync_fence = Fence.New(render.GetDevice()) end

	return sync_fence
end

function render.SubmitAndWait(cmd)
	render.GetQueue():SubmitAndWait(render.GetDevice(), cmd, render.GetSyncFence())
	cmd.keepalive_resources = nil
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

function render.GetScreenTexture()
	return render.target:GetTexture()
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
	r32_sfloat = 32 / 8,
}

function render.GetVulkanFormatSize(format)
	if not formats[format] then error("unknown format: " .. tostring(format)) end

	return formats[format]
end

function render.CreateBlankTexture(size, format, filtering)
	return Texture.New{
		width = size.x,
		height = size.y,
		format = format or "r8g8b8a8_unorm",
		sampler = {
			min_filter = filtering or "linear",
			mag_filter = filtering or "linear",
		},
	}
end

function render.GetWidth()
	return render.target:GetExtent().width
end

function render.GetHeight()
	return render.target:GetExtent().height
end

function render.GetAspectRatio()
	return render.GetWidth() / render.GetHeight()
end

function render.TriggerValidationError()
	local create_info = vulkan.vk.VkBufferCreateInfo{
		sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO + 10, -- INVALID STYPE,
		pNext = nil,
		flags = 1110, -- INVALID FLAGS
		size = 0, -- INVALID SIZE
		usage = vulkan.vk.VkBufferUsageFlagBits.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
		sharingMode = vulkan.vk.VkSharingMode.VK_SHARING_MODE_EXCLUSIVE,
		queueFamilyIndexCount = 0,
		pQueueFamilyIndices = nil,
	}
	local buffer = ffi.new("void*[1]")
	assert(
		vulkan.lib.vkCreateBuffer(assert(vulkan_instance.device.ptr[0]), create_info, nil, buffer) ~= 0
	)
end

return render
