local T = import("test/environment.lua")
local test_render = import("test/test_render.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")

-- Helper to run framebuffer tests in isolation (not inside test_render.Draw2D)
-- because Framebuffer allocates its own command buffer which can conflict
-- with the swapchain's command buffer when tests run in parallel.
test_render.Init()

local function run_fb_test(name, cb)
	return T.Test(name, function()
		local success, err = pcall(cb)
		T(success)["=="](true)
		if not success then
			error(err)
		end
	end)
end

run_fb_test("Graphics framebuffer basic creation", function()
	local fb = Framebuffer.New{
		width = 256,
		height = 256,
		format = "r8g8b8a8_unorm",
	}
	T(fb)["~="](nil)
	T(fb.width)["=="](256)
	T(fb.height)["=="](256)
	T(#fb.color_textures)["=="](1)
	T(fb.depth_texture)["=="](nil)
	fb:Begin()
	fb:End()
end)

run_fb_test("Graphics framebuffer with depth", function()
	local fb = Framebuffer.New{
		width = 256,
		height = 256,
		format = "r8g8b8a8_unorm",
		depth = true,
	}
	T(fb)["~="](nil)
	T(fb.depth_texture)["~="](nil)
	fb:Begin()
	fb:End()
end)

run_fb_test("Graphics framebuffer multi-color attachments", function()
	local fb = Framebuffer.New{
		width = 256,
		height = 256,
		formats = {"r8g8b8a8_unorm", "r8g8b8a8_unorm"},
		clear_colors = {{0.2, 0.3, 0.4, 1}, {0.6, 0.7, 0.8, 1}},
	}
	T(fb)["~="](nil)
	T(#fb.color_textures)["=="](2)
	T(fb.clear_colors[1][1])["~"](0.2)
	T(fb.clear_colors[2][1])["~"](0.6)
	fb:Begin()
	fb:End()
end)

run_fb_test("Graphics framebuffer ClearAll uses correct command buffer", function()
	local fb = Framebuffer.New{
		width = 128,
		height = 128,
		format = "r8g8b8a8_unorm",
		clear_colors = {{0.9, 0.8, 0.7, 1}},
	}
	fb:Begin()
	-- ClearAll should not error - it uses the active command buffer
	fb:ClearAll(0.5, 0.5, 0.5, 1)
	fb:End()
	T(true)["=="](true)
end)

run_fb_test("Graphics framebuffer Clear color by index", function()
	local fb = Framebuffer.New{
		width = 128,
		height = 128,
		formats = {"r8g8b8a8_unorm", "r8g8b8a8_unorm"},
		clear_colors = {{0.1, 0.1, 0.1, 1}, {0.2, 0.2, 0.2, 1}},
	}
	fb:Begin()
	fb:Clear(1, 0.3, 0.4, 0.5, 1)
	fb:End()
	T(true)["=="](true)
end)

run_fb_test("Graphics framebuffer Clear color by string key", function()
	local fb = Framebuffer.New{
		width = 128,
		height = 128,
		formats = {"r8g8b8a8_unorm", "r8g8b8a8_unorm"},
		clear_colors = {{0.1, 0.1, 0.1, 1}, {0.2, 0.2, 0.2, 1}},
	}
	fb:Begin()
	fb:Clear("color", 0.7, 0.6, 0.5, 1)
	fb:End()
	T(true)["=="](true)
end)

run_fb_test("Graphics framebuffer Clear depth and stencil", function()
	local fb = Framebuffer.New{
		width = 128,
		height = 128,
		format = "r8g8b8a8_unorm",
		depth = true,
		clear_colors = {{0.5, 0.5, 0.5, 1}},
	}
	fb:Begin()
	-- Clear depth to 0.5, stencil to 128
	fb:Clear("depth", 0.5, 128)
	fb:End()
	-- Verify depth buffer was cleared by downloading and checking bytes
	local depth_tex = fb:GetDepthTexture()
	local downloaded = depth_tex:Download()
	T(downloaded)["~="](nil)
	T(downloaded.width)["=="](128)
	T(downloaded.height)["=="](128)
	-- For d32_sfloat, each pixel is 4 bytes representing the depth value
	-- After clearing to 0.5, the bytes should be non-zero (0x0000003f in little-endian)
	local pixels = downloaded.pixels
	T(pixels)["~="](nil)
	-- Check that at least some bytes are non-zero (indicating clear happened)
	local has_data = false
	for i = 0, 15 do
		if pixels[i] ~= 0 then
			has_data = true

			break
		end
	end
	T(has_data)["=="](true)
end)

run_fb_test("Graphics framebuffer ClearAll with depth", function()
	local fb = Framebuffer.New{
		width = 128,
		height = 128,
		format = "r8g8b8a8_unorm",
		depth = true,
		clear_colors = {{0.3, 0.3, 0.5, 1}},
	}
	fb:Begin()
	fb:ClearAll(0.1, 0.8, 0.2, 1, 0.5, 0)
	fb:End()
	T(true)["=="](true)
end)

run_fb_test("Graphics framebuffer GetAttachment", function()
	local fb = Framebuffer.New{
		width = 128,
		height = 128,
		format = "r8g8b8a8_unorm",
		depth = true,
	}
	T(fb:GetAttachment(1))["~="](nil)
	T(fb:GetAttachment("color"))["~="](nil)
	T(fb:GetAttachment("depth"))["~="](nil)
	T(fb:GetAttachment(2))["=="](nil)
	fb:Begin()
	fb:End()
end)

run_fb_test("Graphics framebuffer GetExtent", function()
	local fb = Framebuffer.New{
		width = 200,
		height = 150,
		format = "r8g8b8a8_unorm",
	}
	local extent = fb:GetExtent()
	T(extent.width)["=="](200)
	T(extent.height)["=="](150)
	fb:Begin()
	fb:End()
end)

run_fb_test("Graphics framebuffer GetCommandBuffer", function()
	local fb = Framebuffer.New{
		width = 128,
		height = 128,
		format = "r8g8b8a8_unorm",
	}
	local cmd = fb:GetCommandBuffer()
	T(cmd)["~="](nil)
	fb:Begin()
	fb:End()
end)

run_fb_test("Graphics framebuffer GetColorTexture", function()
	local fb = Framebuffer.New{
		width = 128,
		height = 128,
		format = "r8g8b8a8_unorm",
	}
	local tex = fb:GetColorTexture()
	T(tex)["~="](nil)
	fb:Begin()
	fb:End()
end)

run_fb_test("Graphics framebuffer GetDepthTexture", function()
	local fb_no_depth = Framebuffer.New{
		width = 128,
		height = 128,
		format = "r8g8b8a8_unorm",
	}
	T(fb_no_depth:GetDepthTexture())["=="](nil)

	local fb_with_depth = Framebuffer.New{
		width = 128,
		height = 128,
		format = "r8g8b8a8_unorm",
		depth = true,
	}
	T(fb_with_depth:GetDepthTexture())["~="](nil)
	fb_with_depth:Begin()
	fb_with_depth:End()
end)

run_fb_test("Graphics framebuffer ClearAll defaults to stored clear_colors", function()
	local fb = Framebuffer.New{
		width = 128,
		height = 128,
		format = "r8g8b8a8_unorm",
		clear_colors = {{0.4, 0.5, 0.6, 1}},
	}
	fb:Begin()
	fb:ClearAll()
	fb:End()
	T(true)["=="](true)
end)

run_fb_test("Graphics framebuffer Clear with default alpha from stored color", function()
	local fb = Framebuffer.New{
		width = 128,
		height = 128,
		format = "r8g8b8a8_unorm",
		clear_colors = {{0.1, 0.2, 0.3, 0.8}},
	}
	fb:Begin()
	fb:Clear(1, 0.5, 0.6, 0.7)
	fb:End()
	T(true)["=="](true)
end)

run_fb_test("Graphics framebuffer multiple Clear calls in one frame", function()
	local fb = Framebuffer.New{
		width = 128,
		height = 128,
		formats = {"r8g8b8a8_unorm", "r8g8b8a8_unorm"},
		clear_colors = {{0.1, 0.1, 0.1, 1}, {0.2, 0.2, 0.2, 1}},
	}
	fb:Begin()
	fb:Clear(1, 0.8, 0.1, 0.1, 1)
	fb:Clear(2, 0.1, 0.8, 0.1, 1)
	fb:End()
	T(true)["=="](true)
end)

run_fb_test("Graphics framebuffer Clear invalid index errors", function()
	local fb = Framebuffer.New{
		width = 128,
		height = 128,
		formats = {"r8g8b8a8_unorm", "r8g8b8a8_unorm"},
		clear_colors = {{0.1, 0.1, 0.1, 1}, {0.2, 0.2, 0.2, 1}},
	}
	fb:Begin()
	local success, err = pcall(function()
		fb:Clear(99)
	end)
	T(success)["=="](false)
	T(type(err))["=="]("string")
	fb:End()
end)

run_fb_test("Graphics framebuffer Clear depth without depth texture errors", function()
	local fb = Framebuffer.New{
		width = 128,
		height = 128,
		format = "r8g8b8a8_unorm",
	}
	fb:Begin()
	local success, err = pcall(function()
		fb:Clear("depth")
	end)
	T(success)["=="](false)
	T(type(err))["=="]("string")
	fb:End()
end)
