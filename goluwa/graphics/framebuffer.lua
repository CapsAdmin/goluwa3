local Texture = require("graphics.texture")
local ImageView = require("graphics.vulkan.internal.image_view")
local CommandPool = require("graphics.vulkan.internal.command_pool")
local Fence = require("graphics.vulkan.internal.fence")
local render = require("graphics.render")
local Framebuffer = {}
Framebuffer.__index = Framebuffer

function Framebuffer.New(config)
	local width = config.width or 512
	local height = config.height or 512
	local format = config.format or "r8g8b8a8_unorm"
	local samples = config.samples or "1"
	local clear_color = config.clear_color or {0, 0, 0, 1}
	local self = setmetatable({}, Framebuffer)
	self.width = width
	self.height = height
	self.format = format
	self.samples = samples
	self.clear_color = clear_color
	self.color_texture = Texture.New(
		{
			width = width,
			height = height,
			format = format,
			mip_map_levels = config.mip_map_levels or 1,
			image = {
				usage = {"color_attachment", "sampled", "transfer_src"},
				samples = samples,
			},
			sampler = {
				min_filter = config.min_filter or "linear",
				mag_filter = config.mag_filter or "linear",
			},
		}
	)

	if config.depth then
		self.depth_texture = Texture.New(
			{
				width = width,
				height = height,
				format = config.depth_format or "d32_sfloat",
				image = {
					usage = {"depth_stencil_attachment"},
					properties = "device_local",
					samples = samples,
				},
				view = {
					aspect = "depth",
				},
				sampler = false,
			}
		)
	end

	self.command_pool = render.GetCommandPool()
	self.cmd = self.command_pool:AllocateCommandBuffer()
	self.fence = Fence.New(render.GetDevice())
	return self
end

function Framebuffer:Begin(cmd)
	cmd = cmd or self.cmd

	if cmd == self.cmd then
		self.cmd:Reset()
		self.cmd:Begin()
	end

	-- Transition color attachment to optimal layout
	cmd:PipelineBarrier(
		{
			srcStage = "top_of_pipe",
			dstStage = "color_attachment_output",
			imageBarriers = {
				{
					image = self.color_texture:GetImage(),
					srcAccessMask = "none",
					dstAccessMask = "color_attachment_write",
					oldLayout = "undefined",
					newLayout = "color_attachment_optimal",
				},
			},
		}
	)
	-- Begin rendering
	local rendering_info = {
		color_image_view = self.color_texture:GetView(),
		w = self.width,
		h = self.height,
		clear_color = self.clear_color,
	}

	if self.depth_texture then
		rendering_info.depth_image_view = self.depth_texture:GetView()
		rendering_info.clear_depth = 1.0
	end

	cmd:BeginRendering(rendering_info)
	cmd:SetViewport(0.0, 0.0, self.width, self.height, 0.0, 1.0)
	cmd:SetScissor(0, 0, self.width, self.height)
	return cmd
end

function Framebuffer:End(cmd)
	cmd = cmd or self.cmd
	cmd:EndRendering()
	-- Transition color attachment to shader read layout
	cmd:PipelineBarrier(
		{
			srcStage = "color_attachment_output",
			dstStage = "fragment",
			imageBarriers = {
				{
					image = self.color_texture:GetImage(),
					srcAccessMask = "color_attachment_write",
					dstAccessMask = "shader_read",
					oldLayout = "color_attachment_optimal",
					newLayout = "shader_read_only_optimal",
				},
			},
		}
	)

	if cmd == self.cmd then
		self.cmd:End()
		local device = render.GetDevice()
		local queue = render.GetQueue()
		queue:SubmitAndWait(device, self.cmd, self.fence)
	end
end

function Framebuffer:GetAttachment(key)
	if key == "color" then
		return self.color_texture
	elseif key == "depth" and self.depth_texture then
		return self.depth_texture
	end

	return nil
end

function Framebuffer:GetColorTexture()
	return self.color_texture
end

function Framebuffer:GetDepthTexture()
	return self.depth_texture
end

function Framebuffer:GetCommandBuffer()
	return self.cmd
end

function Framebuffer:GetExtent()
	return {width = self.width, height = self.height}
end

return Framebuffer
