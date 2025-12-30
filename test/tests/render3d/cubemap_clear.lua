local vk = require("bindings.vk")

if not pcall(vk.find_library) then
	print("Vulkan library not available, skipping cubemap tests.")
	return
end

local T = require("test.environment")
local ffi = require("ffi")
local render = require("render.render")
local Texture = require("render.texture")
local vulkan = require("render.vulkan.internal.vulkan")
local Buffer = require("render.vulkan.internal.buffer")
local Fence = require("render.vulkan.internal.fence")
local Color = require("structs.color")

T.Test("cubemap clear and validate", function()
	render.Initialize({headless = true})
	local width, height = 32, 32
	local tex = Texture.New(
		{
			width = width,
			height = height,
			format = "r8g8b8a8_unorm",
			image = {
				array_layers = 6,
				flags = {"cube_compatible"},
				usage = {"transfer_dst", "transfer_src", "sampled"},
			},
			view = {
				view_type = "cube",
			},
		}
	)
	local device = render.GetDevice()
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	-- Transition to transfer_dst_optimal
	cmd:Begin()
	cmd:PipelineBarrier(
		{
			srcStage = "top_of_pipe",
			dstStage = "transfer",
			imageBarriers = {
				{
					image = tex:GetImage(),
					oldLayout = "undefined",
					newLayout = "transfer_dst_optimal",
					srcAccessMask = "none",
					dstAccessMask = "transfer_write",
					layer_count = 6,
				},
			},
		}
	)
	local face_colors = {
		Color(1, 0, 0), -- +X: Red
		Color(0, 1, 0), -- -X: Green
		Color(0, 0, 1), -- +Y: Blue
		Color(1, 1, 0), -- -Y: Yellow
		Color(1, 0, 1), -- +Z: Magenta
		Color(0, 1, 1), -- -Z: Cyan
	}

	for i, color in ipairs(face_colors) do
		cmd:ClearColorImage(
			{
				image = tex:GetImage(),
				color = {color:Unpack()},
				base_array_layer = i - 1,
				layer_count = 1,
			}
		)
	end

	-- Transition to transfer_src_optimal for downloading
	cmd:PipelineBarrier(
		{
			srcStage = "transfer",
			dstStage = "transfer",
			imageBarriers = {
				{
					image = tex:GetImage(),
					oldLayout = "transfer_dst_optimal",
					newLayout = "transfer_src_optimal",
					srcAccessMask = "transfer_write",
					dstAccessMask = "transfer_read",
					layer_count = 6,
				},
			},
		}
	)
	cmd:End()
	local fence = Fence.New(device)
	render.GetQueue():SubmitAndWait(device, cmd, fence)

	-- Validate each face
	for i, color in ipairs(face_colors) do
		local staging_buffer = Buffer.New(
			{
				device = device,
				size = width * height * 4,
				usage = "transfer_dst",
				properties = {"host_visible", "host_coherent"},
			}
		)
		local copy_cmd = render.GetCommandPool():AllocateCommandBuffer()
		copy_cmd:Begin()
		copy_cmd:CopyImageToBuffer(
			{
				image = tex:GetImage(),
				buffer = staging_buffer,
				base_array_layer = i - 1,
				layer_count = 1,
				image_layout = "transfer_src_optimal",
				width = width,
				height = height,
			}
		)
		copy_cmd:End()
		local copy_fence = Fence.New(device)
		render.GetQueue():SubmitAndWait(device, copy_cmd, copy_fence)
		local pixel_data = staging_buffer:Map()
		local pixels = ffi.cast("uint8_t*", pixel_data)
		local x = math.floor(width / 2)
		local y = math.floor(height / 2)
		local tolerance = Color() + 0
		local expected = color
		local offset = (y * width + x) * 4
		local color = Color(pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3]) / 255
		assert(
			(color - expected):Abs() <= tolerance,
			string.format(
				"Face %d pixel (%d,%d) R mismatch: got %s, expected %s",
				i - 1,
				x,
				y,
				tostring(color),
				tostring(expected)
			)
		)
		staging_buffer:Unmap()
	end
end)
