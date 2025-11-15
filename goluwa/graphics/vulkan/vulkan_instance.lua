local ffi = require("ffi")
local Instance = require("graphics.vulkan.internal.instance")
local Device = require("graphics.vulkan.internal.device")
local PhysicalDevice = require("graphics.vulkan.internal.physical_device")
local Buffer = require("graphics.vulkan.internal.buffer")
local CommandBuffer = require("graphics.vulkan.internal.command_buffer")
local CommandPool = require("graphics.vulkan.internal.command_pool")
local ComputePipeline = require("graphics.vulkan.internal.compute_pipeline")
local DescriptorPool = require("graphics.vulkan.internal.descriptor_pool")
local DescriptorSetLayout = require("graphics.vulkan.internal.descriptor_set_layout")
local Fence = require("graphics.vulkan.internal.fence")
local Framebuffer = require("graphics.vulkan.internal.framebuffer")
local GraphicsPipeline = require("graphics.vulkan.internal.graphics_pipeline")
local Image = require("graphics.vulkan.internal.image")
local ImageView = require("graphics.vulkan.internal.image_view")
local PipelineLayout = require("graphics.vulkan.internal.pipeline_layout")
local Queue = require("graphics.vulkan.internal.queue")
local RenderPass = require("graphics.vulkan.internal.render_pass")
local Sampler = require("graphics.vulkan.internal.sampler")
local Semaphore = require("graphics.vulkan.internal.semaphore")
local ShaderModule = require("graphics.vulkan.internal.shader_module")
local SwapChain = require("graphics.vulkan.internal.swap_chain")
local Surface = require("graphics.vulkan.internal.surface")
local process = require("bindings.process")
local OffscreenRenderTarget = require("graphics.vulkan.rendertarget_offscreen")
local WindowRenderTarget = require("graphics.vulkan.rendertarget_window")
local Pipeline = require("graphics.vulkan.graphics_pipeline")
local ComputePipeline = require("graphics.vulkan.compute_pipeline")
local VulkanInstance = {}
VulkanInstance.__index = VulkanInstance
local VULKAN_SDK = "/Users/caps/VulkanSDK/1.4.328.1"
process.setenv("VULKAN_SDK", VULKAN_SDK)
process.setenv("VK_LAYER_PATH", VULKAN_SDK .. "/macOS/share/vulkan/explicit_layer.d")

function VulkanInstance.New(surface_handle)
	local self = setmetatable({}, VulkanInstance)
	self.instance = Instance.New(
		{"VK_KHR_surface", "VK_EXT_metal_surface", "VK_KHR_portability_enumeration"},
		{"VK_LAYER_KHRONOS_validation"}
	)
	self.surface = Surface.New(self.instance, surface_handle)
	self.physical_device = self.instance:GetPhysicalDevices()[1]
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
	config.vulkan_instance = self
	return OffscreenRenderTarget.New(config)
end

function VulkanInstance:CreateWindowRenderTarget(config)
	return WindowRenderTarget.New(self, config)
end

function VulkanInstance:CreateGraphicsPipeline(...)
	return Pipeline.New(self, ...)
end

function VulkanInstance:CreateComputePipeline(...)
	return ComputePipeline.New(self, ...)
end

return VulkanInstance
