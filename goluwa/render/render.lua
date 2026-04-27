local ffi = require("ffi")
local render = {}
import.loaded["goluwa/render/render.lua"] = render
render.default_bindless_descriptor_capacities = {
	textures = 4096,
	cubemaps = 256,
}
render.bindless_descriptor_capacities = {
	textures = render.default_bindless_descriptor_capacities.textures,
	cubemaps = render.default_bindless_descriptor_capacities.cubemaps,
}

function render.GetBindlessDescriptorCapacities()
	return {
		textures = render.bindless_descriptor_capacities.textures,
		cubemaps = render.bindless_descriptor_capacities.cubemaps,
	}
end

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
render.initializing = false

local function query_bindless_sampled_image_limit()
	if
		not vulkan_instance or
		vulkan_instance == NULL or
		not vulkan_instance.physical_device
	then
		return nil
	end

	local properties = vulkan_instance.physical_device:GetProperties()
	local limits = properties.limits
	local descriptor_indexing_properties = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceDescriptorIndexingProperties)()
	descriptor_indexing_properties[0].sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_PROPERTIES
	descriptor_indexing_properties[0].pNext = nil
	local properties2 = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceProperties2)()
	properties2[0].sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2
	properties2[0].pNext = descriptor_indexing_properties
	vulkan.lib.vkGetPhysicalDeviceProperties2(vulkan_instance.physical_device.ptr[0], properties2)
	local descriptor_limits = descriptor_indexing_properties[0]
	local descriptor_set_limit = tonumber(descriptor_limits.maxDescriptorSetUpdateAfterBindSampledImages)
	local per_stage_limit = tonumber(descriptor_limits.maxPerStageDescriptorUpdateAfterBindSampledImages)

	if descriptor_set_limit == 0 then
		descriptor_set_limit = tonumber(limits.maxDescriptorSetSampledImages)
	end

	if per_stage_limit == 0 then
		per_stage_limit = tonumber(limits.maxPerStageDescriptorSampledImages)
	end

	return math.min(descriptor_set_limit, per_stage_limit)
end

local function refresh_bindless_descriptor_capacities()
	local defaults = render.default_bindless_descriptor_capacities
	local sampled_image_limit = query_bindless_sampled_image_limit()

	if not sampled_image_limit or sampled_image_limit <= 0 then
		render.bindless_descriptor_capacities = {
			textures = defaults.textures,
			cubemaps = defaults.cubemaps,
		}
		return
	end

	local default_total = defaults.textures + defaults.cubemaps

	if sampled_image_limit >= default_total then
		render.bindless_descriptor_capacities = {
			textures = defaults.textures,
			cubemaps = defaults.cubemaps,
		}
		return
	end

	local textures = math.max(1, math.floor(sampled_image_limit * (defaults.textures / default_total)))
	local cubemaps = math.max(0, sampled_image_limit - textures)

	if cubemaps == 0 and defaults.cubemaps > 0 and sampled_image_limit > 1 then
		cubemaps = 1
		textures = sampled_image_limit - cubemaps
	end

	render.bindless_descriptor_capacities = {
		textures = math.min(textures, defaults.textures),
		cubemaps = math.min(cubemaps, defaults.cubemaps),
	}
end

function render.IsInitialized()
	return render.available and
		render.target ~= nil and
		render.target ~= NULL and
		render.target:IsValid() and
		vulkan_instance ~= nil and
		vulkan_instance ~= NULL and
		vulkan_instance.device ~= nil
end

function render.CanCreateResources()
	return render.IsInitialized() or render.initializing
end

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
	render.bindless_descriptor_capacities = {
		textures = render.default_bindless_descriptor_capacities.textures,
		cubemaps = render.default_bindless_descriptor_capacities.cubemaps,
	}
	sync_fence = NULL
	render.shutting_down = false
end

function render.Initialize(config)
	config = config or {}
	local is_headless = config.headless
	render.initializing = true

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

	refresh_bindless_descriptor_capacities()
	event.Call("RendererReady")
	render.initializing = false

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

local function get_active_recording_command_buffer()
	local stack = render.command_buffer_stack

	for i = #stack, 1, -1 do
		local cmd = stack[i]

		if cmd and cmd.is_recording then return cmd end
	end

	if render.cmd and render.cmd.is_recording then return render.cmd end

	return nil
end

function render.GetCommandBuffer()
	return get_active_recording_command_buffer()
end

function render.GetCommandBufferOutsideRendering()
	local cmd = get_active_recording_command_buffer()

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
	local sampler_config_keys = {
		"min_filter",
		"mag_filter",
		"mipmap_mode",
		"wrap_s",
		"wrap_t",
		"wrap_r",
		"max_lod",
		"min_lod",
		"mip_lod_bias",
		"anisotropy",
		"border_color",
		"unnormalized_coordinates",
		"compare_enable",
		"compare_op",
		"flags",
	}

	local function copy_sampler_config(config)
		if config == false then return false end

		if type(config) ~= "table" then return nil end

		local out = {}

		for _, key in ipairs(sampler_config_keys) do
			local value = config[key]

			if value ~= nil then out[key] = value end
		end

		return out
	end

	local function get_sampler_config_key(config)
		local normalized = copy_sampler_config(config)

		if normalized == false or normalized == nil then return normalized end

		local parts = {}

		for i, key in ipairs(sampler_config_keys) do
			local value = normalized[key]
			parts[i] = value == nil and "_" or (key .. "=" .. type(value) .. ":" .. tostring(value))
		end

		return table.concat(parts, "|")
	end

	function render.CreateSampler(config)
		local normalized = assert(copy_sampler_config(config), "render.CreateSampler: invalid sampler config")
		local hash = get_sampler_config_key(normalized)

		if render.cached_samplers[hash] then return render.cached_samplers[hash] end

		normalized.device = vulkan_instance.device
		local sampler = Sampler.New(normalized)
		render.cached_samplers[hash] = sampler
		return sampler
	end

	local function apply_sampler_filter_override(config, filter_name, filter)
		if filter == nil then return end

		if filter == "nearest" then
			config[filter_name] = "nearest"
			config.anisotropy = 1
		elseif filter == "linear" then
			config[filter_name] = "linear"
		elseif filter == "anisotropic" then
			config[filter_name] = "linear"
			config.anisotropy = math.max(config.anisotropy or 1, 16)
		else
			error(
				"render.BuildSamplerFilterConfig: unsupported filter override " .. tostring(filter),
				2
			)
		end
	end

	function render.BuildSamplerFilterConfig(min_filter_override, mag_filter_override)
		if min_filter_override == nil and mag_filter_override == nil then return nil end

		local config = {}
		apply_sampler_filter_override(config, "min_filter", min_filter_override)
		apply_sampler_filter_override(config, "mag_filter", mag_filter_override)
		return next(config) and config or nil
	end

	local function normalize_sampler_filter(filter, level)
		if filter == nil then return nil end

		if filter == "nearest" or filter == "linear" or filter == "anisotropic" then
			return filter
		end

		error("render sampler filter must be nearest, linear, or anisotropic", level or 2)
	end

	local function get_sampler_filter_stack(state, key)
		state = state or render.sampler_filter_state

		if type(state) ~= "table" then
			error("render sampler filter state expected", 3)
		end

		local stack = state[key]

		if stack then return stack end

		stack = {}
		state[key] = stack
		return stack
	end

	function render.CreateSamplerFilterState()
		return {
			min_filter_stack = {},
			mag_filter_stack = {},
		}
	end

	render.sampler_filter_state = render.sampler_filter_state or render.CreateSamplerFilterState()

	function render.PushSamplerFilterMin(state, filter)
		table.insert(
			get_sampler_filter_stack(state, "min_filter_stack"),
			normalize_sampler_filter(filter, 3)
		)
	end

	function render.PushSamplerFilterMag(state, filter)
		table.insert(
			get_sampler_filter_stack(state, "mag_filter_stack"),
			normalize_sampler_filter(filter, 3)
		)
	end

	function render.PopSamplerFilterMin(state)
		table.remove(get_sampler_filter_stack(state, "min_filter_stack"))
	end

	function render.PopSamplerFilterMag(state)
		table.remove(get_sampler_filter_stack(state, "mag_filter_stack"))
	end

	function render.GetActiveSamplerFilterMin(state)
		local stack = get_sampler_filter_stack(state, "min_filter_stack")
		return stack[#stack]
	end

	function render.GetActiveSamplerFilterMag(state)
		local stack = get_sampler_filter_stack(state, "mag_filter_stack")
		return stack[#stack]
	end

	function render.GetSamplerFilterConfig(state)
		return render.BuildSamplerFilterConfig(render.GetActiveSamplerFilterMin(state), render.GetActiveSamplerFilterMag(state))
	end

	function render.PushFilterMin(filter)
		return render.PushSamplerFilterMin(nil, filter)
	end

	function render.PushFilterMag(filter)
		return render.PushSamplerFilterMag(nil, filter)
	end

	function render.PopFilterMin()
		return render.PopSamplerFilterMin(nil)
	end

	function render.PopFilterMag()
		return render.PopSamplerFilterMag(nil)
	end

	function render.GetActiveFilterMin()
		return render.GetActiveSamplerFilterMin(nil)
	end

	function render.GetActiveFilterMag()
		return render.GetActiveSamplerFilterMag(nil)
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
