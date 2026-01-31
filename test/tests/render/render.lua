local T = require("test.environment")
local render = require("render.render")
local Texture = require("render.texture")

T.Test("Graphics render multiple outputs", function()
	local width, height = 512, 512
	render.Initialize({headless = true, width = width, height = height})
	-- Create 3 textures for outputs
	local tex1 = Texture.New(
		{
			width = width,
			height = height,
			format = "r8g8b8a8_unorm",
			image = {usage = {"color_attachment", "sampled", "transfer_src"}},
		}
	)
	local tex2 = Texture.New(
		{
			width = width,
			height = height,
			format = "r8g8b8a8_unorm",
			image = {usage = {"color_attachment", "sampled", "transfer_src"}},
		}
	)
	local tex3 = Texture.New(
		{
			width = width,
			height = height,
			format = "r8g8b8a8_unorm",
			image = {usage = {"color_attachment", "sampled", "transfer_src"}},
		}
	)
	-- Create pipeline with 3 outputs
	local pipeline = render.CreateGraphicsPipeline(
		{
			color_format = {"r8g8b8a8_unorm", "r8g8b8a8_unorm", "r8g8b8a8_unorm"},
			shader_stages = {
				{
					type = "vertex",
					code = [[
					#version 450
					void main() {
						vec2 uv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
						gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
					}
				]],
				},
				{
					type = "fragment",
					code = [[
					#version 450
					layout(location = 0) out vec4 out1;
					layout(location = 1) out vec4 out2;
					layout(location = 2) out vec4 out3;
					void main() {
						out1 = vec4(1.0, 0.0, 0.0, 1.0);
						out2 = vec4(0.0, 1.0, 0.0, 1.0);
						out3 = vec4(0.0, 0.0, 1.0, 1.0);
					}
				]],
				},
			},
			rasterizer = {cull_mode = "none"},
			color_blend = {
				attachments = {
					{blend = false, color_write_mask = {"r", "g", "b", "a"}},
					{blend = false, color_write_mask = {"r", "g", "b", "a"}},
					{blend = false, color_write_mask = {"r", "g", "b", "a"}},
				},
			},
		}
	)
	render.BeginFrame()
	local cmd = render.GetCommandBuffer()
	cmd:EndRendering()
	-- Transition textures to color_attachment_optimal
	cmd:PipelineBarrier(
		{
			srcStage = "top_of_pipe",
			dstStage = "color_attachment_output",
			imageBarriers = {
				{image = tex1:GetImage(), newLayout = "color_attachment_optimal"},
				{image = tex2:GetImage(), newLayout = "color_attachment_optimal"},
				{image = tex3:GetImage(), newLayout = "color_attachment_optimal"},
			},
		}
	)
	cmd:BeginRendering(
		{
			w = width,
			h = height,
			color_attachments = {
				{color_image_view = tex1:GetView(), clear_color = {0, 0, 0, 0}},
				{color_image_view = tex2:GetView(), clear_color = {0, 0, 0, 0}},
				{color_image_view = tex3:GetView(), clear_color = {0, 0, 0, 0}},
			},
		}
	)
	cmd:SetViewport(0, 0, width, height, 0, 1)
	cmd:SetScissor(0, 0, width, height)
	pipeline:Bind(cmd, render.GetCurrentFrame())
	cmd:Draw(3, 1, 0, 0)
	cmd:EndRendering()
	-- Transition to transfer_src_optimal for downloading
	cmd:PipelineBarrier(
		{
			srcStage = "color_attachment_output",
			dstStage = "transfer",
			imageBarriers = {
				{
					image = tex1:GetImage(),
					srcAccessMask = "color_attachment_write",
					dstAccessMask = "transfer_read",
					oldLayout = "color_attachment_optimal",
					newLayout = "transfer_src_optimal",
				},
				{
					image = tex2:GetImage(),
					srcAccessMask = "color_attachment_write",
					dstAccessMask = "transfer_read",
					oldLayout = "color_attachment_optimal",
					newLayout = "transfer_src_optimal",
				},
				{
					image = tex3:GetImage(),
					srcAccessMask = "color_attachment_write",
					dstAccessMask = "transfer_read",
					oldLayout = "color_attachment_optimal",
					newLayout = "transfer_src_optimal",
				},
			},
		}
	)
	render.EndFrame()
	-- Verify colors
	local r, g, b, a = tex1:GetPixel(width / 2, height / 2)
	T(r / 255)["~"](1.0)
	T(g / 255)["~"](0.0)
	T(b / 255)["~"](0.0)
	r, g, b, a = tex2:GetPixel(width / 2, height / 2)
	T(r / 255)["~"](0.0)
	T(g / 255)["~"](1.0)
	T(b / 255)["~"](0.0)
	r, g, b, a = tex3:GetPixel(width / 2, height / 2)
	T(r / 255)["~"](0.0)
	T(g / 255)["~"](0.0)
	T(b / 255)["~"](1.0)
end)
