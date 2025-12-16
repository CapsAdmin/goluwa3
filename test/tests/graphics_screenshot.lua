local T = require("test.environment")
local ffi = require("ffi")
local png_encode = require("file_formats.png.encode")

T.Test("Graphics offscreen rendering and screenshot", function()
	local render = require("graphics.render")

	-- Initialize headless graphics (no window required)
	if not render.window_target then render.InitializeHeadless() end

	-- Test parameters
	local width = 256
	local height = 256
	-- Create offscreen render target
	local offscreen = render.CreateOffscreenRenderTarget(
		{
			width = width,
			height = height,
			format = "r8g8b8a8_unorm",
			usage = {"color_attachment", "transfer_src"},
			samples = "1",
			final_layout = "transfer_src_optimal",
		}
	)
	T(offscreen)["~="](nil)
	T(offscreen.width)["=="](width)
	T(offscreen.height)["=="](height)
	-- Create a simple graphics pipeline for rendering
	local pipeline = render.CreateGraphicsPipeline(
		{
			dynamic_states = {"viewport", "scissor"},
			color_format = "r8g8b8a8_unorm",
			depth_format = false, -- No depth buffer
			samples = "1",
			shader_stages = {
				{
					type = "vertex",
					code = [[
					#version 450
					
					vec2 positions[3] = vec2[](
						vec2(-0.5, -0.5),
						vec2( 0.5, -0.5),
						vec2( 0.0,  0.5)
					);
					
					vec3 colors[3] = vec3[](
						vec3(1.0, 0.0, 0.0),
						vec3(0.0, 1.0, 0.0),
						vec3(0.0, 0.0, 1.0)
					);
					
					layout(location = 0) out vec3 fragColor;
					
					void main() {
						gl_Position = vec4(positions[gl_VertexIndex], 0.0, 1.0);
						fragColor = colors[gl_VertexIndex];
					}
				]],
				},
				{
					type = "fragment",
					code = [[
					#version 450
					
					layout(location = 0) in vec3 fragColor;
					layout(location = 0) out vec4 outColor;
					
					void main() {
						outColor = vec4(fragColor, 1.0);
					}
				]],
				},
			},
		}
	)
	T(pipeline)["~="](nil)
	-- Begin rendering
	offscreen:BeginFrame()
	local cmd = offscreen:GetCommandBuffer()
	-- Begin rendering (dynamic rendering)
	cmd:BeginRendering(
		{
			color_image_view = offscreen:GetImageView(),
			clear_color = {0.1, 0.1, 0.1, 1.0},
			x = 0,
			y = 0,
			w = width,
			h = height,
		}
	)
	-- Set viewport and scissor
	cmd:SetViewport(0, 0, width, height, 0, 1)
	cmd:SetScissor(0, 0, width, height)
	-- Bind pipeline and draw
	pipeline:Bind(cmd)
	cmd:Draw(3, 1, 0, 0)
	-- End rendering
	cmd:EndRendering()
	-- End frame (submits and waits)
	offscreen:EndFrame()
	-- Create staging buffer to copy image data to
	local Buffer = require("graphics.vulkan.internal.buffer")
	local device = render.GetDevice()
	local staging_buffer = Buffer.New(
		{
			device = device,
			size = width * height * 4,
			usage = "transfer_dst",
			properties = {"host_visible", "host_coherent"},
		}
	)
	T(staging_buffer)["~="](nil)
	-- Copy image to staging buffer
	local cmd_pool = render.GetCommandPool()
	local copy_cmd = cmd_pool:AllocateCommandBuffer()
	copy_cmd:Begin()
	-- Copy image to buffer
	local vulkan = require("graphics.vulkan.internal.vulkan")
	vulkan.lib.vkCmdCopyImageToBuffer(
		copy_cmd.ptr[0],
		offscreen.image.ptr[0],
		vulkan.vk.e.VkImageLayout("transfer_src_optimal"),
		staging_buffer.ptr[0],
		1,
		vulkan.vk.VkBufferImageCopy(
			{
				bufferOffset = 0,
				bufferRowLength = 0,
				bufferImageHeight = 0,
				imageSubresource = vulkan.vk.s.ImageSubresourceLayers(
					{
						aspectMask = "color",
						mipLevel = 0,
						baseArrayLayer = 0,
						layerCount = 1,
					}
				),
				imageOffset = vulkan.vk.VkOffset3D({x = 0, y = 0, z = 0}),
				imageExtent = vulkan.vk.VkExtent3D({width = width, height = height, depth = 1}),
			}
		)
	)
	copy_cmd:End()
	-- Submit and wait
	local Fence = require("graphics.vulkan.internal.fence")
	local fence = Fence.New(device)
	local queue = render.GetQueue()
	queue:SubmitAndWait(device, copy_cmd, fence)
	-- Map staging buffer and read pixel data
	local pixel_data = staging_buffer:Map()
	-- Copy pixel data to a Lua-managed buffer for PNG encoding
	local pixels = ffi.new("uint8_t[?]", width * height * 4)
	ffi.copy(pixels, pixel_data, width * height * 4)
	staging_buffer:Unmap()
	-- Verify we have some non-zero pixel data
	local has_data = false

	for i = 0, width * height * 4 - 1 do
		if pixels[i] ~= 0 then
			has_data = true

			break
		end
	end

	T(has_data)["=="](true)
	-- Encode as PNG
	local png = png_encode(width, height, "rgba")
	-- Convert pixel data to table for PNG encoder
	local pixel_table = {}

	for i = 0, width * height * 4 - 1 do
		pixel_table[i + 1] = pixels[i]
	end

	png:write(pixel_table)
	local png_data = png:getData()
	T(#png_data)[">"](0)
	-- Create screenshots directory if it doesn't exist
	local fs = require("fs")
	local screenshot_dir = "./logs/screenshots"
	fs.create_directory_recursive(screenshot_dir)
	-- Save PNG file
	local screenshot_path = screenshot_dir .. "/test_triangle.png"
	local file = assert(io.open(screenshot_path, "wb"))
	file:write(png_data)
	file:close()
	print("Screenshot saved to: " .. screenshot_path)
	-- Verify file was created
	local verify_file = io.open(screenshot_path, "rb")
	T(verify_file)["~="](nil)

	if verify_file then
		local file_size = verify_file:seek("end")
		verify_file:close()
		T(file_size)[">"](0)
		print("Screenshot file size: " .. file_size .. " bytes")
	end
end)
