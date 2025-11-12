local OffscreenRenderTarget = {}
OffscreenRenderTarget.__index = OffscreenRenderTarget

function OffscreenRenderTarget.New(renderer, width, height, format, config)
	config = config or {}
	local usage = config.usage or {"color_attachment", "sampled"}
	local samples = config.samples or "1"
	local final_layout = config.final_layout or "color_attachment_optimal"
	local self = setmetatable({}, OffscreenRenderTarget)
	self.renderer = renderer
	self.width = width
	self.height = height
	self.format = format
	self.final_layout = final_layout
	-- Create the image
	self.image = renderer.device:CreateImage(width, height, format, usage, "device_local", samples)
	-- Create image view
	self.image_view = self.image:CreateView()
	-- Create render pass for this format (with offscreen-appropriate final layout)
	self.render_pass = renderer.device:CreateRenderPass({
		format = format,
		samples = samples,
		final_layout = final_layout,
	})
	-- Create framebuffer
	self.framebuffer = renderer.device:CreateFramebuffer(self.render_pass, self.image_view, width, height, nil)
	-- Create command pool and buffer for offscreen rendering
	self.command_pool = renderer.device:CreateCommandPool(renderer.graphics_queue_family)
	self.command_buffer = self.command_pool:CreateCommandBuffer()
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
	local fence = self.renderer.device:CreateFence()
	self.renderer.queue:SubmitAndWait(self.renderer.device, self.command_buffer, fence)
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
