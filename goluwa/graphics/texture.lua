local ffi = require("ffi")
local render = require("graphics.render")
local file_formats = require("file_formats")
local Vec2f = require("structs.vec2").Vec2f
local Texture = {}
Texture.__index = Texture

function Texture.New(config)
	if config.path then
		local img = file_formats.LoadPNG(config.path)
		config.width = img.width
		config.height = img.height
		config.format = "R8G8B8A8_UNORM"
		config.buffer = img.buffer:GetBuffer()
	end

	local image = render.CreateImage(
		config.width,
		config.height,
		config.format or "R8G8B8A8_UNORM",
		{"sampled", "transfer_dst", "transfer_src", "color_attachment"},
		"device_local"
	)

	if config.buffer then
		render.UploadToImage(image, config.buffer, image:GetWidth(), image:GetHeight())
	else
		-- If no buffer is provided, transition the image to shader_read_only_optimal
		-- This is necessary because images start in undefined layout
		image:TransitionLayout("undefined", "shader_read_only_optimal")
	end

	local view = image:CreateView()
	local sampler = render.CreateSampler(
		{
			min_filter = config.min_filter or "nearest",
			mag_filter = config.mag_filter or "nearest",
			wrap_s = config.wrap_s or "repeat",
			wrap_t = config.wrap_t or "repeat",
		}
	)
	return setmetatable(
		{
			image = image,
			view = view,
			sampler = sampler,
			mip_map_levels = config.mip_map_levels or 1,
			format = config.format or "R8G8B8A8_UNORM",
			config = config,
		},
		Texture
	)
end

function Texture:GetImage()
	return self.image
end

function Texture:GetView()
	return self.view
end

function Texture:GetSampler()
	return self.sampler
end

function Texture:GetSize()
	return Vec2f(self.image:GetWidth(), self.image:GetHeight())
end

function Texture:GenerateMipMap()
	if self.mip_map_levels <= 1 then return end
--TODO: implement mipmap generation
end

do
	function Texture:Shade(glsl)
		local RenderPass = require("graphics.vulkan.internal.render_pass")
		local Framebuffer = require("graphics.vulkan.internal.framebuffer")
		local CommandPool = require("graphics.vulkan.internal.command_pool")
		local Fence = require("graphics.vulkan.internal.fence")
		local device = render.GetDevice()
		local queue = render.GetQueue()
		local graphics_queue_family = render.GetGraphicsQueueFamily()
		-- Create render pass for this texture's format
		local render_pass = RenderPass.New(
			device,
			{
				format = self.format,
				samples = "1",
				final_layout = "shader_read_only_optimal",
			}
		)
		-- Create framebuffer using the texture's existing image view
		local framebuffer = Framebuffer.New(
			device,
			render_pass,
			self.view,
			self.image:GetWidth(),
			self.image:GetHeight(),
			nil
		)
		-- Create command pool and buffer for this operation
		local command_pool = CommandPool.New(device, graphics_queue_family)
		local cmd = command_pool:CreateCommandBuffer()
		-- Create graphics pipeline
		local pipeline = render.CreateGraphicsPipeline(
			{
				dynamic_states = {"viewport", "scissor"},
				render_pass = render_pass,
				shader_stages = {
					{
						type = "vertex",
						code = [[
						#version 450

						// Full-screen triangle
						vec2 positions[3] = vec2[](
							vec2(-1.0, -1.0),
							vec2( 3.0, -1.0),
							vec2(-1.0,  3.0)
						);

						layout(location = 0) out vec2 frag_uv;

						void main() {
							vec2 pos = positions[gl_VertexIndex];
							gl_Position = vec4(pos, 0.0, 1.0);
							frag_uv = pos * 0.5 + 0.5;
						}
					]],
						input_assembly = {
							topology = "triangle_list",
							primitive_restart = false,
						},
					},
					{
						type = "fragment",
						code = [[
							#version 450

							layout(location = 0) in vec2 in_uv;
							layout(location = 0) out vec4 out_color;

							vec4 shade(vec2 uv) {
								]] .. glsl .. [[
							}

							void main() {
								out_color = shade(in_uv);
							}
						]],
					},
				},
				rasterizer = {
					depth_clamp = false,
					discard = false,
					polygon_mode = "fill",
					line_width = 1.0,
					cull_mode = "front",
					front_face = "counter_clockwise",
					depth_bias = 0,
				},
				color_blend = {
					logic_op_enabled = false,
					logic_op = "copy",
					constants = {0.0, 0.0, 0.0, 0.0},
					attachments = {
						{
							blend = false,
							src_color_blend_factor = "src_alpha",
							dst_color_blend_factor = "one_minus_src_alpha",
							color_blend_op = "add",
							src_alpha_blend_factor = "one",
							dst_alpha_blend_factor = "zero",
							alpha_blend_op = "add",
							color_write_mask = {"r", "g", "b", "a"},
						},
					},
				},
				multisampling = {
					sample_shading = false,
					rasterization_samples = "1",
				},
				depth_stencil = {
					depth_test = false,
					depth_write = false,
					depth_compare_op = "less",
					depth_bounds_test = false,
					stencil_test = false,
				},
			}
		)
		-- Begin recording commands
		cmd:Reset()
		cmd:Begin()
		-- Transition image from undefined/shader_read to color_attachment_optimal
		--collectgarbage("stop")
		cmd:PipelineBarrier(
			{
				srcStage = "top_of_pipe",
				dstStage = "color_attachment_output",
				imageBarriers = {
					{
						image = self.image,
						srcAccessMask = "none",
						dstAccessMask = "color_attachment_write",
						oldLayout = "undefined",
						newLayout = "color_attachment_optimal",
					},
				},
			}
		)
		pipeline:Bind(cmd)
		-- Begin render pass
		cmd:BeginRenderPass(
			render_pass,
			framebuffer,
			{width = self.image:GetWidth(), height = self.image:GetHeight()},
			{0, 0, 0, 1}
		)
		-- Draw fullscreen triangle
		cmd:SetViewport(0.0, 0.0, self.image:GetWidth(), self.image:GetHeight(), 0.0, 1.0)
		cmd:SetScissor(0, 0, self.image:GetWidth(), self.image:GetHeight())
		cmd:Draw(3, 1, 0, 0)
		-- End render pass
		-- Note: The render pass automatically transitions the image to shader_read_only_optimal
		-- because we set final_layout = "shader_read_only_optimal" in CreateRenderPass
		cmd:EndRenderPass()
		-- End command buffer
		cmd:End()
		-- Submit and wait
		local fence = Fence.New(device)
		self.refs = {cmd, render_pass, framebuffer, command_pool, pipeline, fence}
		queue:SubmitAndWait(device, cmd, fence)
		device:WaitIdle() -- Ensure ALL device operations are complete
	end
end

return Texture
