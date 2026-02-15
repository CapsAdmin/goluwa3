local Texture = require("render.texture")
local ImageView = require("render.vulkan.internal.image_view")
local CommandPool = require("render.vulkan.internal.command_pool")
local render = require("render.render")
local prototype = require("prototype")
local Framebuffer = prototype.CreateTemplate("render_framebuffer")

function Framebuffer.New(config)
	local width = config.width or 512
	local height = config.height or 512
	local samples = config.samples or "1"
	local self = Framebuffer:CreateObject()
	self.width = width
	self.height = height
	self.samples = samples
	self.color_textures = {}
	self.clear_colors = {}
	local formats = config.formats or {config.format or "r8g8b8a8_unorm"}
	local clear_colors = config.clear_colors or {config.clear_color or {0, 0, 0, 1}}

	for i, format in ipairs(formats) do
		local color_texture = Texture.New(
			{
				width = width,
				height = height,
				format = format,
				mip_map_levels = config.mip_map_levels or 1,
				image = {
					usage = {"color_attachment", "sampled", "transfer_src", "transfer_dst"},
					samples = samples,
				},
				sampler = {
					min_filter = config.min_filter or "linear",
					mag_filter = config.mag_filter or "linear",
					wrap_s = config.wrap_s or "repeat",
					wrap_t = config.wrap_t or "repeat",
				},
			}
		)
		table.insert(self.color_textures, color_texture)
		table.insert(self.clear_colors, clear_colors[i] or {0, 0, 0, 1})
	end

	self.color_texture = self.color_textures[1]
	self.clear_color = self.clear_colors[1]

	if config.depth then
		self.depth_texture = Texture.New(
			{
				width = width,
				height = height,
				format = config.depth_format or "d32_sfloat",
				image = {
					usage = {"depth_stencil_attachment", "sampled"},
					properties = "device_local",
					samples = samples,
				},
				view = {
					aspect = "depth",
				},
				sampler = {
					min_filter = "linear",
					mag_filter = "linear",
				},
			}
		)
	end

	self.command_pool = render.GetCommandPool()
	self.cmd = self.command_pool:AllocateCommandBuffer()
	return self
end

function Framebuffer:Begin(cmd, load_op)
	cmd = cmd or self.cmd
	load_op = load_op or "clear"

	if cmd == self.cmd then
		self.cmd:Reset()
		self.cmd:Begin()
	end

	-- Transition color attachments to optimal layout
	local imageBarriers = {}

	for _, tex in ipairs(self.color_textures) do
		table.insert(
			imageBarriers,
			{
				image = tex:GetImage(),
				srcAccessMask = "none",
				dstAccessMask = "color_attachment_write",
				oldLayout = self.initialized and "shader_read_only_optimal" or "undefined",
				newLayout = "color_attachment_optimal",
			}
		)
	end

	if self.depth_texture then
		table.insert(
			imageBarriers,
			{
				image = self.depth_texture:GetImage(),
				srcAccessMask = "none",
				dstAccessMask = "depth_stencil_attachment_write",
				oldLayout = self.initialized and "shader_read_only_optimal" or "undefined",
				newLayout = "depth_stencil_attachment_optimal",
			-- aspect is automatically determined from image format by PipelineBarrier
			}
		)
	end

	cmd:PipelineBarrier(
		{
			srcStage = "top_of_pipe",
			dstStage = {"color_attachment_output", "early_fragment_tests", "late_fragment_tests"},
			imageBarriers = imageBarriers,
		}
	)
	-- Begin rendering
	local color_attachments = {}

	for i, tex in ipairs(self.color_textures) do
		table.insert(
			color_attachments,
			{
				color_image_view = tex:GetView(),
				clear_color = self.clear_colors[i],
				load_op = load_op,
				store_op = "store",
			}
		)
	end

	local rendering_info = {
		color_attachments = color_attachments,
		w = self.width,
		h = self.height,
	}

	if self.depth_texture then
		rendering_info.depth_image_view = self.depth_texture:GetView()
		rendering_info.clear_depth = 1.0
		rendering_info.depth_store = true
	end

	cmd:BeginRendering(rendering_info)
	cmd:SetViewport(0.0, 0.0, self.width, self.height, 0.0, 1.0)
	cmd:SetScissor(0, 0, self.width, self.height)
	return cmd
end

function Framebuffer:End(cmd)
	cmd = cmd or self.cmd
	cmd:EndRendering()
	-- Transition color attachments to shader read layout
	local imageBarriers = {}

	for _, tex in ipairs(self.color_textures) do
		table.insert(
			imageBarriers,
			{
				image = tex:GetImage(),
				srcAccessMask = "color_attachment_write",
				dstAccessMask = "shader_read",
				oldLayout = "color_attachment_optimal",
				newLayout = "shader_read_only_optimal",
			}
		)
	end

	if self.depth_texture then
		table.insert(
			imageBarriers,
			{
				image = self.depth_texture:GetImage(),
				srcAccessMask = "depth_stencil_attachment_write",
				dstAccessMask = "shader_read",
				oldLayout = "depth_attachment_optimal",
				newLayout = "shader_read_only_optimal",
			-- aspect is automatically determined from image format by PipelineBarrier
			}
		)
	end

	cmd:PipelineBarrier(
		{
			srcStage = {"color_attachment_output", "late_fragment_tests"},
			dstStage = "fragment",
			imageBarriers = imageBarriers,
		}
	)
	self.initialized = true

	for _, tex in ipairs(self.color_textures) do
		tex:GetImage().layout = "shader_read_only_optimal"
	end

	if self.depth_texture then
		self.depth_texture:GetImage().layout = "shader_read_only_optimal"
	end

	if cmd == self.cmd then
		self.cmd:End()
		render.SubmitAndWait(self.cmd)
	end
end

function Framebuffer:GetAttachment(key)
	if type(key) == "number" then return self.color_textures[key] end

	if key == "color" then
		return self.color_textures[1]
	elseif key == "depth" and self.depth_texture then
		return self.depth_texture
	end

	return nil
end

function Framebuffer:GetColorTexture()
	return self.color_textures[1]
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

return Framebuffer:Register()
