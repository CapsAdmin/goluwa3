local ffi = require("ffi")
local prototype = import("goluwa/prototype.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local Instance = import("goluwa/render/vulkan/internal/instance.lua")
local Device = import("goluwa/render/vulkan/internal/device.lua")
local PhysicalDevice = import("goluwa/render/vulkan/internal/physical_device.lua")
local Buffer = import("goluwa/render/vulkan/internal/buffer.lua")
local CommandPool = import("goluwa/render/vulkan/internal/command_pool.lua")
local Surface = import("goluwa/render/vulkan/internal/surface.lua")
local GraphicsPipeline = import("goluwa/render/vulkan/graphics_pipeline.lua")
local ComputePipeline = import("goluwa/render/vulkan/compute_pipeline.lua")
local OcclusionQuery = import("goluwa/render/vulkan/internal/occlusion_query.lua")
local process = import("goluwa/bindings/process.lua")

if jit.os == "OSX" then
	local VULKAN_SDK = "/Users/caps/VulkanSDK/1.4.328.1"
	process.setenv("VULKAN_SDK", VULKAN_SDK)
	process.setenv("VK_LAYER_PATH", VULKAN_SDK .. "/macOS/share/vulkan/explicit_layer.d")
end

-- On Linux, VK_LAYER_PATH should be set by the environment (e.g., nix develop)
local VulkanInstance = prototype.CreateTemplate("render_vulkan_instance")

function VulkanInstance.New(surface_handle, display_handle)
	local self = VulkanInstance:CreateObject({})
	local is_headless = not surface_handle and not display_handle
	-- Setup extensions based on headless or windowed mode
	local extensions = {}
	local required_extensions = {}
	local surface_ext

	if not is_headless then
		-- Platform-specific surface extension
		surface_ext = jit.os == "OSX" and "VK_EXT_metal_surface" or jit.os == "Windows" and "VK_KHR_win32_surface" or "VK_KHR_wayland_surface"
		table.insert(extensions, "VK_KHR_surface")
		table.insert(extensions, surface_ext)
		table.insert(extensions, "VK_EXT_swapchain_colorspace")
		required_extensions["VK_KHR_surface"] = true
		required_extensions[surface_ext] = true
	end

	if jit.os == "OSX" then
		table.insert(extensions, "VK_KHR_portability_enumeration")
	end

	do
		local available_instance_extensions = vulkan.GetAvailableExtensions()
		local filtered_extensions = {}

		for _, ext in ipairs(extensions) do
			if table.has_value(available_instance_extensions, ext) then
				table.insert(filtered_extensions, ext)
			elseif required_extensions[ext] then
				error("Required Vulkan instance extension not supported: " .. ext)
			else
				logn("Instance extension " .. ext .. " not supported by loader")
			end
		end

		extensions = filtered_extensions
	end

	local validation_layers = nil

	if os.getenv("VK_INSTANCE_LAYERS") then
		logn("Using VK_INSTANCE_LAYERS from environment: " .. os.getenv("VK_INSTANCE_LAYERS"))
	else
		local available_layers = vulkan.GetAvailableLayers()

		for _, layer in ipairs(available_layers) do
			if layer == "VK_LAYER_KHRONOS_validation" then
				validation_layers = {"VK_LAYER_KHRONOS_validation"}

				break
			end
		end
	end

	self.instance = Instance.New(extensions, validation_layers)

	-- Create surface only if not headless
	if not is_headless then
		self.surface = Surface.New(self.instance, surface_handle, display_handle)
	else
		self.surface = nil
	end

	-- Find the best physical device
	local physical_devices = self.instance:GetPhysicalDevices()
	self.physical_device = nil
	local best_score = -1

	for i, device in ipairs(physical_devices) do
		local props = device:GetProperties()
		local device_name = ffi.string(props.deviceName)
		-- Check surface support only if not headless
		local supports_requirements = is_headless or device:SupportsSurface(self.surface)

		if supports_requirements then
			local score = 0

			-- VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU = 2
			if props.deviceType == 2 then
				score = 1000
			-- VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU = 1
			elseif props.deviceType == 1 then
				score = 100
			else
				score = 10
			end

			if score > best_score then
				self.physical_device = device
				best_score = score
			end
		end
	end

	if not self.physical_device then
		local error_msg = is_headless and
			"No physical device found!" or
			"No physical device supports the surface!"
		error(error_msg)
	end

	local props = self.physical_device:GetProperties()
	local device_name = ffi.string(props.deviceName)
	self.graphics_queue_family = self.physical_device:FindGraphicsQueueFamily(self.surface)
	local available_extensions = self.physical_device:GetAvailableDeviceExtensions()
	local requested_device_extensions = {
		"VK_EXT_conditional_rendering",
		"VK_EXT_scalar_block_layout",
		"VK_EXT_extended_dynamic_state",
		"VK_EXT_extended_dynamic_state3",
	}

	if not is_headless then
		table.insert(requested_device_extensions, "VK_KHR_swapchain")
	end

	local device_extensions = {}

	for _, ext in ipairs(requested_device_extensions) do
		if table.has_value(available_extensions, ext) then
			table.insert(device_extensions, ext)
		else
			logn("Extension " .. ext .. " not supported by physical device " .. device_name)
		end
	end

	self.device = Device.New(self.physical_device, device_extensions, self.graphics_queue_family)
	self.command_pool = CommandPool.New(self.device, self.graphics_queue_family)
	self.queue = self.device:GetQueue(self.graphics_queue_family)
	return self
end

function VulkanInstance:CreateBuffer(config)
	local byte_size = config.byte_size
	assert(
		byte_size and byte_size > 0,
		"buffer byte_size must be specified and greater than 0"
	)
	local data = config.data

	if data then
		if type(data) == "table" then
			data = ffi.new((config.data_type or "float") .. "[" .. (#data) .. "]", data)
			byte_size = byte_size or ffi.sizeof(data)
		else
			byte_size = byte_size or ffi.sizeof(data)
		end
	end

	local buffer = Buffer.New{
		device = self.device,
		size = byte_size,
		usage = config.buffer_usage,
		properties = config.memory_property,
	}

	if data then buffer:CopyData(data, byte_size) end

	return buffer
end

function VulkanInstance:CreateWindowRenderTarget(config)
	local ImageRenderTarget = import("goluwa/render/vulkan/image_rendertarget.lua")
	return ImageRenderTarget.New(self, config)
end

function VulkanInstance:CreateGraphicsPipeline(config)
	return GraphicsPipeline.New(self, config)
end

function VulkanInstance:CreateComputePipeline(config)
	return ComputePipeline.New(self, config)
end

function VulkanInstance:CreateOcclusionQuery()
	return OcclusionQuery.New{device = self.device, instance = self.instance}
end

function VulkanInstance:OnRemove()
	if self.device and self.device:IsValid() then self.device:WaitIdle() end

	if self.command_pool then self.command_pool:Remove() end

	if self.device then self.device:Remove() end

	if self.surface then self.surface:Remove() end

	if self.instance then self.instance:Remove() end
end

return VulkanInstance:Register()
