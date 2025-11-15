local Image = require("graphics.vulkan.internal.image")
local ImageView = require("graphics.vulkan.internal.image_view")
local RenderPass = require("graphics.vulkan.internal.render_pass")
local Framebuffer = require("graphics.vulkan.internal.framebuffer")
local CommandBuffer = require("graphics.vulkan.internal.command_buffer")
local Semaphore = require("graphics.vulkan.internal.semaphore")
local Fence = require("graphics.vulkan.internal.fence")
local OffscreenRenderTarget = {}
OffscreenRenderTarget.__index = OffscreenRenderTarget

function OffscreenRenderTarget.New(vulkan_instance, config)
	local width = config.width
	local height = config.height
	local format = config.format
	local usage = config.usage or {"color_attachment", "sampled"}
	local samples = config.samples or "1"
	local final_layout = config.final_layout or "color_attachment_optimal"
	local self = setmetatable({}, OffscreenRenderTarget)
	self.vulkan_instance = vulkan_instance
	self.width = width
	self.height = height
	self.format = format
	self.final_layout = final_layout
	self.image = Image.New(
		{
			device = vulkan_instance.device,
			width = width,
			height = height,
			format = format,
			usage = usage,
			properties = "device_local",
			samples = samples,
		}
	)
	self.image_view = ImageView.New(
		{
			device = vulkan_instance.device,
			image = self.image,
			format = format,
			aspect = "color",
		}
	)
	self.render_pass = RenderPass.New(
		vulkan_instance.device,
		{
			format = format,
			samples = samples,
			final_layout = final_layout,
		}
	)
	self.framebuffer = Framebuffer.New(
		{
			device = vulkan_instance.device,
			render_pass = self.render_pass,
			image_view = self.image_view,
			width = width,
			height = height,
		}
	)
	self.command_buffer = vulkan_instance.command_pool:AllocateCommandBuffer()
	return self
end

function OffscreenRenderTarget:GetImageView()
	return self.image_view
end

function OffscreenRenderTarget:GetRenderPass()
	return self.render_pass
end

function OffscreenRenderTarget:WriteMode(cmd)
	cmd:PipelineBarrier(
		{
			srcStage = "fragment",
			dstStage = "all_commands",
			imageBarriers = {
				{
					image = self.image,
					srcAccessMask = "shader_read",
					dstAccessMask = "color_attachment_write",
					oldLayout = "shader_read_only_optimal",
					newLayout = "color_attachment_optimal",
				},
			},
		}
	)
end

function OffscreenRenderTarget:ReadMode(cmd)
	cmd:PipelineBarrier(
		{
			srcStage = "all_commands",
			dstStage = "fragment",
			imageBarriers = {
				{
					image = self.image,
					srcAccessMask = "color_attachment_write",
					dstAccessMask = "shader_read",
					oldLayout = "color_attachment_optimal",
					newLayout = "shader_read_only_optimal",
				},
			},
		}
	)
end

function OffscreenRenderTarget:BeginFrame()
	self.command_buffer:Reset()
	self.command_buffer:Begin()
	return true
end

function OffscreenRenderTarget:EndFrame()
	self.command_buffer:End()
	local fence = Fence.New(self.vulkan_instance.device)
	self.vulkan_instance.queue:SubmitAndWait(self.vulkan_instance.device, self.command_buffer, fence)
end

function OffscreenRenderTarget:GetCommandBuffer()
	return self.command_buffer
end

function OffscreenRenderTarget:GetFramebuffer()
	return self.framebuffer
end

function OffscreenRenderTarget:GetExtent()
	return {width = self.width, height = self.height}
end

return OffscreenRenderTarget
