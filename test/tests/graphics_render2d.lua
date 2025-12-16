local T = require("test.environment")
local ffi = require("ffi")
local png_encode = require("file_formats.png.encode")

T.Test("Graphics render2d drawing example", function()
	local render = require("graphics.render")
	local render2d = require("graphics.render2d")
	local event = require("event")

	-- Initialize headless graphics (no window required)
	if not render.window_target then render.InitializeHeadless() end

	-- Initialize render2d
	render2d.Initialize()
	-- Test parameters
	local width = 512
	local height = 512
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
	-- Begin rendering
	offscreen:BeginFrame()
	local cmd = offscreen:GetCommandBuffer()
	-- Transition image from undefined to color_attachment_optimal
	local vulkan = require("graphics.vulkan.internal.vulkan")
	cmd:PipelineBarrier(
		{
			srcStage = "top_of_pipe",
			dstStage = "color_attachment_output",
			imageBarriers = {
				{
					image = offscreen.image,
					subresourceRange = {
						aspectMask = "color",
						baseMipLevel = 0,
						levelCount = 1,
						baseArrayLayer = 0,
						layerCount = 1,
					},
					srcAccessMask = {},
					dstAccessMask = "color_attachment_write",
					oldLayout = "undefined",
					newLayout = "color_attachment_optimal",
				},
			},
		}
	)
	-- Begin rendering (dynamic rendering)
	cmd:BeginRendering(
		{
			color_image_view = offscreen:GetImageView(),
			clear_color = {0.1, 0.1, 0.2, 1.0}, -- Dark blue background
			x = 0,
			y = 0,
			w = width,
			h = height,
		}
	)
	-- Set viewport and scissor for render2d
	cmd:SetViewport(0, 0, width, height, 0, 1)
	cmd:SetScissor(0, 0, width, height)
	-- Update render2d screen size
	render2d.UpdateScreenSize({w = width, h = height})
	-- Simulate the Draw2D event by setting up render2d context
	local frame_index = 1 -- Lua uses 1-based indexing
	render2d.cmd = cmd
	render2d.pipeline:Bind(cmd, frame_index)
	render2d.SetBlendMode("alpha", true) -- force=true to set dynamic state
	-- Example 1: Draw a red rectangle
	render2d.SetColor(1, 0, 0, 1) -- Red
	print("Drawing red rectangle at 50,50 with size 100x100")
	render2d.DrawRect(50, 50, 100, 100) -- x, y, width, height
	-- Example 2: Draw a green rectangle with rotation
	render2d.SetColor(0, 1, 0, 1) -- Green
	render2d.DrawRect(200, 50, 80, 80, math.rad(45)) -- Rotated 45 degrees
	-- Example 3: Draw a blue triangle
	render2d.SetColor(0, 0, 1, 1) -- Blue
	render2d.DrawTriangle(400, 100, 60, 60)
	-- Example 4: Draw semi-transparent yellow rectangle
	render2d.SetColor(1, 1, 0, 0.5) -- Yellow, 50% transparent
	render2d.DrawRect(100, 200, 150, 80)

	-- Example 5: Draw multiple colored rectangles in a grid
	for i = 0, 3 do
		for j = 0, 3 do
			local hue = (i * 4 + j) / 16
			-- Simple HSV to RGB conversion for rainbow colors
			local r = math.abs(hue * 6 - 3) - 1
			local g = 2 - math.abs(hue * 6 - 2)
			local b = 2 - math.abs(hue * 6 - 4)
			r = math.max(0, math.min(1, r))
			g = math.max(0, math.min(1, g))
			b = math.max(0, math.min(1, b))
			render2d.SetColor(r, g, b, 1)
			render2d.DrawRect(50 + i * 50, 320 + j * 30, 40, 25)
		end
	end

	-- Example 6: Draw with blend modes
	render2d.SetBlendMode("additive")
	render2d.SetColor(1, 0, 0, 0.5)
	render2d.DrawRect(300, 250, 100, 100)
	render2d.SetColor(0, 1, 0, 0.5)
	render2d.DrawRect(350, 250, 100, 100)
	render2d.SetColor(0, 0, 1, 0.5)
	render2d.DrawRect(325, 300, 100, 100)
	-- Reset to alpha blending
	render2d.SetBlendMode("alpha")
	-- Example 7: Using matrix transformations
	render2d.PushMatrix()
	render2d.Translate(400, 400)
	render2d.Rotate(math.rad(30))
	render2d.Scale(2, 1) -- Stretch horizontally
	render2d.SetColor(1, 0.5, 0, 1) -- Orange
	render2d.DrawRect(0, 0, 40, 40)
	render2d.PopMatrix()
	-- End rendering
	cmd:EndRendering()
	-- Transition image layout from color_attachment_optimal to transfer_src_optimal
	local vulkan = require("graphics.vulkan.internal.vulkan")
	cmd:PipelineBarrier(
		{
			srcStage = "color_attachment_output",
			dstStage = "transfer",
			imageBarriers = {
				{
					image = offscreen.image,
					subresourceRange = {
						aspectMask = "color",
						baseMipLevel = 0,
						levelCount = 1,
						baseArrayLayer = 0,
						layerCount = 1,
					},
					srcAccessMask = "color_attachment_write",
					dstAccessMask = "transfer_read",
					oldLayout = "color_attachment_optimal",
					newLayout = "transfer_src_optimal",
				},
			},
		}
	)
	offscreen:EndFrame()
	-- Copy rendered image to CPU
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
	-- Copy image to buffer
	local cmd_pool = render.GetCommandPool()
	local copy_cmd = cmd_pool:AllocateCommandBuffer()
	copy_cmd:Begin()
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
	local screenshot_path = screenshot_dir .. "/render2d_example.png"
	local file = assert(io.open(screenshot_path, "wb"))
	file:write(png_data)
	file:close()
	print("Render2D screenshot saved to: " .. screenshot_path)
	-- Verify file was created
	local verify_file = io.open(screenshot_path, "rb")
	T(verify_file)["~="](nil)

	if verify_file then
		local file_size = verify_file:seek("end")
		verify_file:close()
		T(file_size)[">"](0)
		print("Render2D screenshot file size: " .. file_size .. " bytes")
	end
end)
