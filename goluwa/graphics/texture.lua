local ffi = require("ffi")
local render = require("graphics.render")
local file_formats = require("file_formats")
local Vec2f = require("structs.vec2").Vec2f
local Buffer = require("graphics.vulkan.internal.buffer")
local CommandPool = require("graphics.vulkan.internal.command_pool")
local Fence = require("graphics.vulkan.internal.fence")
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

	local mip_levels = config.mip_map_levels or 1

	if mip_levels == "auto" then mip_levels = 999 end

	if mip_levels > 1 then
		mip_levels = math.floor(math.log(math.max(config.width, config.height), 2)) + 1
	end

	local image = render.CreateImage(
		{
			width = config.width,
			height = config.height,
			format = config.format or "R8G8B8A8_UNORM",
			usage = {"sampled", "transfer_dst", "transfer_src", "color_attachment"},
			memory_properties = "device_local",
			mip_levels = mip_levels,
		}
	)
	local view = image:CreateView()
	-- Parse min_filter to separate filter mode and mipmap mode
	local min_filter = config.min_filter or "nearest"
	local mipmap_mode = "nearest"

	if min_filter:find("mipmap") then
		-- Handle formats like "linear_mipmap_linear" or "nearest_mipmap_nearest"
		local parts = {}

		for part in min_filter:gmatch("[^_]+") do
			table.insert(parts, part)
		end

		if #parts == 3 and parts[2] == "mipmap" then
			min_filter = parts[1]
			mipmap_mode = parts[3]
		end
	end

	local sampler = render.CreateSampler(
		{
			min_filter = min_filter,
			mag_filter = config.mag_filter or "nearest",
			mipmap_mode = mipmap_mode,
			wrap_s = config.wrap_s or "repeat",
			wrap_t = config.wrap_t or "repeat",
			max_lod = mip_levels,
		}
	)
	local self = setmetatable(
		{
			image = image,
			view = view,
			sampler = sampler,
			mip_map_levels = mip_levels,
			format = config.format or "R8G8B8A8_UNORM",
			config = config,
		},
		Texture
	)

	if config.buffer then
		-- If we're generating mipmaps, keep mip level 0 in transfer_dst after upload
		self:Upload(config.buffer, mip_levels > 1)
	else
		-- If no buffer is provided, transition the image to shader_read_only_optimal
		-- This is necessary because images start in undefined layout
		image:TransitionLayout("undefined", "shader_read_only_optimal")
	end

	return self
end

function Texture:Upload(data, keep_in_transfer_dst)
	local device = render.GetDevice()
	local queue = render.GetQueue()
	local graphics_queue_family = render.GetGraphicsQueueFamily()
	local width = self.image:GetWidth()
	local height = self.image:GetHeight()
	local pixel_count = width * height
	-- Create staging buffer
	local staging_buffer = Buffer.New(
		{
			device = device,
			size = pixel_count * 4,
			usage = "transfer_src",
			properties = {"host_visible", "host_coherent"},
		}
	)
	staging_buffer:CopyData(data, pixel_count * 4)
	-- Copy to image using command buffer
	local cmd_pool = CommandPool.New(device, graphics_queue_family)
	local cmd = cmd_pool:AllocateCommandBuffer()
	cmd:Begin()
	-- Transition image to transfer dst (only mip level 0)
	cmd:PipelineBarrier(
		{
			srcStage = "compute",
			dstStage = "transfer",
			imageBarriers = {
				{
					image = self.image,
					srcAccessMask = "none",
					dstAccessMask = "transfer_write",
					oldLayout = "undefined",
					newLayout = "transfer_dst_optimal",
					base_mip_level = 0,
					level_count = 1,
				},
			},
		}
	)
	-- Copy buffer to image
	cmd:CopyBufferToImage(staging_buffer, self.image, width, height)

	-- Only transition to final layout if not keeping in transfer_dst for mipmap generation
	if not keep_in_transfer_dst then
		-- Determine final layout based on image usage
		local final_layout = "general"
		local dst_stage = "compute"

		if type(self.image.usage) == "table" then
			for _, usage in ipairs(self.image.usage) do
				if usage == "sampled" then
					final_layout = "shader_read_only_optimal"
					dst_stage = "fragment"

					break
				end
			end
		end

		-- Transition to final layout
		cmd:PipelineBarrier(
			{
				srcStage = "transfer",
				dstStage = dst_stage,
				imageBarriers = {
					{
						image = self.image,
						srcAccessMask = "transfer_write",
						dstAccessMask = "shader_read",
						oldLayout = "transfer_dst_optimal",
						newLayout = final_layout,
						base_mip_level = 0,
						level_count = 1,
					},
				},
			}
		)
	end

	cmd:End()
	-- Submit and wait
	local fence = Fence.New(device)
	queue:SubmitAndWait(device, cmd, fence)
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

function Texture:GenerateMipMap(initial_layout)
	if self.mip_map_levels <= 1 then return end

	local CommandPool = require("graphics.vulkan.internal.command_pool")
	local Fence = require("graphics.vulkan.internal.fence")
	local device = render.GetDevice()
	local queue = render.GetQueue()
	local graphics_queue_family = render.GetGraphicsQueueFamily()
	local command_pool = CommandPool.New(device, graphics_queue_family)
	local cmd = command_pool:AllocateCommandBuffer()
	cmd:Begin()
	-- Determine initial layout (can be transfer_dst_optimal from upload, or shader_read_only_optimal from Shade)
	local old_layout = initial_layout or "transfer_dst_optimal"
	local src_access = old_layout == "transfer_dst_optimal" and "transfer_write" or "shader_read"
	local src_stage = old_layout == "transfer_dst_optimal" and "transfer" or "fragment"
	-- Transition first mip level (0) to transfer_src
	cmd:PipelineBarrier(
		{
			srcStage = src_stage,
			dstStage = "transfer",
			imageBarriers = {
				{
					image = self.image,
					srcAccessMask = src_access,
					dstAccessMask = "transfer_read",
					oldLayout = old_layout,
					newLayout = "transfer_src_optimal",
					base_mip_level = 0,
					level_count = 1,
				},
			},
		}
	)
	local mip_width = self.image:GetWidth()
	local mip_height = self.image:GetHeight()

	-- Generate each mip level by blitting from the previous level
	for i = 1, self.mip_map_levels - 1 do
		local next_mip_width = math.max(1, math.floor(mip_width / 2))
		local next_mip_height = math.max(1, math.floor(mip_height / 2))
		-- Transition current mip level to transfer_dst before blitting into it
		cmd:PipelineBarrier(
			{
				srcStage = "transfer",
				dstStage = "transfer",
				imageBarriers = {
					{
						image = self.image,
						srcAccessMask = "none",
						dstAccessMask = "transfer_write",
						oldLayout = "undefined",
						newLayout = "transfer_dst_optimal",
						base_mip_level = i,
						level_count = 1,
					},
				},
			}
		)
		-- Blit from previous mip level to current mip level
		cmd:BlitImage(
			{
				src_image = self.image,
				dst_image = self.image,
				src_mip_level = i - 1,
				dst_mip_level = i,
				src_width = mip_width,
				src_height = mip_height,
				dst_width = next_mip_width,
				dst_height = next_mip_height,
				src_layout = "transfer_src_optimal",
				dst_layout = "transfer_dst_optimal",
				filter = "linear",
			}
		)
		-- Transition current mip level from transfer_dst to transfer_src
		cmd:PipelineBarrier(
			{
				srcStage = "transfer",
				dstStage = "transfer",
				imageBarriers = {
					{
						image = self.image,
						srcAccessMask = "transfer_write",
						dstAccessMask = "transfer_read",
						oldLayout = "transfer_dst_optimal",
						newLayout = "transfer_src_optimal",
						base_mip_level = i,
						level_count = 1,
					},
				},
			}
		)
		mip_width = next_mip_width
		mip_height = next_mip_height
	end

	-- Transition all mip levels to shader_read_only_optimal for sampling
	cmd:PipelineBarrier(
		{
			srcStage = "transfer",
			dstStage = "fragment",
			imageBarriers = {
				{
					image = self.image,
					srcAccessMask = "transfer_read",
					dstAccessMask = "shader_read",
					oldLayout = "transfer_src_optimal",
					newLayout = "shader_read_only_optimal",
					base_mip_level = 0,
					level_count = self.mip_map_levels,
				},
			},
		}
	)
	cmd:End()
	local fence = Fence.New(device)
	queue:SubmitAndWait(device, cmd, fence)
end

do
	function Texture:Shade(glsl)
		local RenderPass = require("graphics.vulkan.internal.render_pass")
		local Framebuffer = require("graphics.vulkan.internal.framebuffer")
		local ImageView = require("graphics.vulkan.internal.image_view")
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
		-- Create a view for only mip level 0 (required for framebuffer attachment)
		local mip0_view = ImageView.New(
			{
				device = device,
				image = self.image,
				format = self.format,
				base_mip_level = 0,
				level_count = 1,
			}
		)
		-- Create framebuffer using the mip level 0 view
		local framebuffer = Framebuffer.New(
			{
				device = device,
				render_pass = render_pass,
				image_view = mip0_view,
				width = self.image:GetWidth(),
				height = self.image:GetHeight(),
			}
		)
		-- Create command pool and buffer for this operation
		local command_pool = CommandPool.New(device, graphics_queue_family)
		local cmd = command_pool:AllocateCommandBuffer()
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
