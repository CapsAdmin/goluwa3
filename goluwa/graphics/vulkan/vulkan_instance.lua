local ffi = require("ffi")
local Instance = require("graphics.vulkan.internal.instance")
local Device = require("graphics.vulkan.internal.device")
local PhysicalDevice = require("graphics.vulkan.internal.physical_device")
local Buffer = require("graphics.vulkan.internal.buffer")
local CommandPool = require("graphics.vulkan.internal.command_pool")
local Surface = require("graphics.vulkan.internal.surface")
local OffscreenRenderTarget = require("graphics.vulkan.rendertarget_offscreen")
local WindowRenderTarget = require("graphics.vulkan.rendertarget_window")
local GraphicsPipeline = require("graphics.vulkan.graphics_pipeline")
local ComputePipeline = require("graphics.vulkan.compute_pipeline")
local process = require("bindings.process")

do
	local VULKAN_SDK = "/Users/caps/VulkanSDK/1.4.328.1"
	process.setenv("VULKAN_SDK", VULKAN_SDK)
	process.setenv("VK_LAYER_PATH", VULKAN_SDK .. "/macOS/share/vulkan/explicit_layer.d")
end

local VulkanInstance = {}
VulkanInstance.__index = VulkanInstance

function VulkanInstance.New(surface_handle, display_handle)
	local self = setmetatable({}, VulkanInstance)
	-- Platform-specific surface extension
	local surface_ext = jit.os == "OSX" and "VK_EXT_metal_surface" or "VK_KHR_wayland_surface"
	local extensions = {"VK_KHR_surface", surface_ext}

	if jit.os == "OSX" then
		table.insert(extensions, "VK_KHR_portability_enumeration")
	end

	self.instance = Instance.New(extensions, {})
	self.surface = Surface.New(self.instance, surface_handle, display_handle)
	-- Find a physical device that supports this surface
	local physical_devices = self.instance:GetPhysicalDevices()
	self.physical_device = nil
	local best_score = -1

	for i, device in ipairs(physical_devices) do
		local props = device:GetProperties()
		local device_name = ffi.string(props.deviceName)

		if device:SupportsSurface(self.surface) then
			local score = 0

			-- VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU = 2
			if props.deviceType == 2 then
				score = 1000
			-- VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU = 1
			elseif props.deviceType == 1 then
				score = 100
			end

			if score > best_score then
				self.physical_device = device
				best_score = score
			end
		end
	end

	if not self.physical_device then
		error("No physical device supports the Wayland surface!")
	end

	local props = self.physical_device:GetProperties()
	local device_name = ffi.string(props.deviceName)
	print(device_name .. " selected")
	self.graphics_queue_family = self.physical_device:FindGraphicsQueueFamily(self.surface)
	self.device = Device.New(self.physical_device, {"VK_KHR_swapchain"}, self.graphics_queue_family)
	self.command_pool = CommandPool.New(self.device, self.graphics_queue_family)
	self.queue = self.device:GetQueue(self.graphics_queue_family)
	return self
end

function VulkanInstance:CreateBuffer(config)
	local byte_size
	local data = config.data

	if data then
		if type(data) == "table" then
			data = ffi.new((config.data_type or "float") .. "[" .. (#data) .. "]", data)
			byte_size = ffi.sizeof(data)
		else
			byte_size = config.byte_size or ffi.sizeof(data)
		end
	end

	local buffer = Buffer.New(
		{
			device = self.device,
			size = byte_size,
			usage = config.buffer_usage,
			properties = config.memory_property,
		}
	)

	if data then buffer:CopyData(data, byte_size) end

	return buffer
end

function VulkanInstance:CreateOffscreenRenderTarget(config)
	return OffscreenRenderTarget.New(self, config)
end

function VulkanInstance:CreateWindowRenderTarget(config)
	return WindowRenderTarget.New(self, config)
end

function VulkanInstance:CreateGraphicsPipeline(config)
	return GraphicsPipeline.New(self, config)
end

function VulkanInstance:CreateComputePipeline(config)
	return ComputePipeline.New(self, config)
end

return VulkanInstance
