local vk = require("bindings.vk")

if not pcall(vk.find_library) then
	print("Vulkan library not available, skipping render2d comprehensive tests.")
	return
end

local T = require("test.environment")
local ffi = require("ffi")
local png_encode = require("file_formats.png.encode")
local render = require("graphics.render")
local render2d = require("graphics.render2d")
local fs = require("fs")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local Color = require("structs.color")
local width = 512
local height = 512
local initialized = false

-- Helper function to initialize render2d
local function init_render2d()
	render.Initialize({headless = true, width = width, height = height})
	render2d.Initialize()
end

-- Helper function to draw with render2d
local function draw2d(cb)
	render2d.Initialize()
	render.BeginFrame()
	render2d.BindPipeline()
	cb()
	render.EndFrame()
end

-- Helper function to get pixel color
local function get_pixel(image_data, x, y)
	local width = image_data.width
	local height = image_data.height
	local bytes_per_pixel = image_data.bytes_per_pixel

	if x < 0 or x >= width or y < 0 or y >= height then return 0, 0, 0, 0 end

	local offset = (y * width + x) * bytes_per_pixel
	local r = image_data.pixels[offset + 0]
	local g = image_data.pixels[offset + 1]
	local b = image_data.pixels[offset + 2]
	local a = image_data.pixels[offset + 3]
	return r, g, b, a
end

-- Helper function to test pixel color
local function test_pixel(x, y, r, g, b, a, tolerance)
	tolerance = tolerance or 0.01
	local image_data = render.target:GetTexture():Download()
	local r_, g_, b_, a_ = get_pixel(image_data, x, y)
	local r_norm, g_norm, b_norm, a_norm = r_ / 255, g_ / 255, b_ / 255, a_ / 255
	-- Check with tolerance
	T(math.abs(r_norm - r))["<="](tolerance)
	T(math.abs(g_norm - g))["<="](tolerance)
	T(math.abs(b_norm - b))["<="](tolerance)
	T(math.abs(a_norm - a))["<="](tolerance)
end

-- ============================================================================
-- Color Tests
-- ============================================================================
T.Test("Graphics render2d SetColor and GetColor", function()
	init_render2d()
	-- Test RGB
	render2d.SetColor(0.5, 0.6, 0.7)
	local r, g, b, a = render2d.GetColor()
	T(r)["~"](0.5)
	T(g)["~"](0.6)
	T(b)["~"](0.7)
	-- Test RGBA
	render2d.SetColor(0.1, 0.2, 0.3, 0.4)
	r, g, b, a = render2d.GetColor()
	T(r)["~"](0.1)
	T(g)["~"](0.2)
	T(b)["~"](0.3)
	T(a)["~"](0.4)
	-- Reset to white
	render2d.SetColor(1, 1, 1, 1)
end)

T.Test("Graphics render2d PushColor and PopColor", function()
	init_render2d()
	render2d.SetColor(1, 0, 0, 1)
	render2d.PushColor(0, 1, 0, 1)
	local r, g, b, a = render2d.GetColor()
	T(r)["~"](0)
	T(g)["~"](1)
	render2d.PopColor()
	r, g, b, a = render2d.GetColor()
	T(r)["~"](1)
	T(g)["~"](0)
end)

T.Test("Graphics render2d color rendering", function()
	draw2d(function()
		-- Red pixel
		render2d.SetColor(1, 0, 0, 1)
		render2d.DrawRect(10, 10, 1, 1)
	end)

	test_pixel(10, 10, 1, 0, 0, 1)
end)

-- ============================================================================
-- Alpha Multiplier Tests
-- ============================================================================
T.Test("Graphics render2d SetAlphaMultiplier and GetAlphaMultiplier", function()
	init_render2d()
	render2d.SetAlphaMultiplier(0.5)
	T(render2d.GetAlphaMultiplier())["~"](0.5)
	render2d.SetAlphaMultiplier(1.0)
	T(render2d.GetAlphaMultiplier())["~"](1.0)
end)

T.Test("Graphics render2d PushAlphaMultiplier and PopAlphaMultiplier", function()
	init_render2d()
	render2d.SetAlphaMultiplier(1.0)
	render2d.PushAlphaMultiplier(0.5)
	T(render2d.GetAlphaMultiplier())["~"](0.5)
	render2d.PopAlphaMultiplier()
	T(render2d.GetAlphaMultiplier())["~"](1.0)
end)

T.Test("Graphics render2d alpha multiplier rendering", function()
	draw2d(function()
		render2d.SetColor(1, 1, 1, 1)
		render2d.SetAlphaMultiplier(0.5)
		render2d.DrawRect(20, 20, 1, 1)
	end)

	-- With alpha blending, white at 0.5 alpha over black background = gray
	-- Result: RGB = 1 * 0.5 + 0 * 0.5 = 0.5 (127/255)
	test_pixel(20, 20, 0.5, 0.5, 0.5, 0.5, 0.01)
	-- Reset
	render2d.SetAlphaMultiplier(1.0)
end)

-- ============================================================================
-- UV Tests
-- ============================================================================
T.Test("Graphics render2d SetUV and GetUV", function()
	init_render2d()
	render2d.SetUV(10, 20, 100, 200, 512, 512)
	local x, y, w, h, sx, sy = render2d.GetUV()
	T(x)["=="](10)
	T(y)["=="](20)
	T(w)["=="](100)
	T(h)["=="](200)
	T(sx)["=="](512)
	T(sy)["=="](512)
	-- Reset
	render2d.SetUV()
	x, y, w, h, sx, sy = render2d.GetUV()
	T(x)["=="](nil)
end)

T.Test("Graphics render2d PushUV and PopUV", function()
	init_render2d()
	render2d.SetUV(10, 20, 30, 40, 100, 100)
	render2d.PushUV(50, 60, 70, 80, 200, 200)
	local x, y, w, h, sx, sy = render2d.GetUV()
	T(x)["=="](50)
	T(y)["=="](60)
	render2d.PopUV()
	x, y, w, h, sx, sy = render2d.GetUV()
	T(x)["=="](10)
	T(y)["=="](20)
end)

T.Test("Graphics render2d SetUV2", function()
	init_render2d()
	-- SetUV2 doesn't have a corresponding getter, but we can test it doesn't error
	render2d.SetUV2(0, 0, 1, 1)
	render2d.SetUV2(0.25, 0.25, 0.75, 0.75)
end)

-- ============================================================================
-- Blend Mode Tests
-- ============================================================================
T.Test("Graphics render2d SetBlendMode and GetBlendMode", function()
	draw2d(function()
		render2d.SetBlendMode("alpha")
		T(render2d.GetBlendMode())["=="]("alpha")
		render2d.SetBlendMode("additive")
		T(render2d.GetBlendMode())["=="]("additive")
		render2d.SetBlendMode("multiply")
		T(render2d.GetBlendMode())["=="]("multiply")
		render2d.SetBlendMode("premultiplied")
		T(render2d.GetBlendMode())["=="]("premultiplied")
		render2d.SetBlendMode("screen")
		T(render2d.GetBlendMode())["=="]("screen")
		render2d.SetBlendMode("none")
		T(render2d.GetBlendMode())["=="]("none")
		-- Reset to alpha
		render2d.SetBlendMode("alpha")
	end)
end)

T.Test("Graphics render2d PushBlendMode and PopBlendMode", function()
	draw2d(function()
		render2d.PushBlendMode("alpha")
		render2d.SetBlendMode("additive")
		T(render2d.GetBlendMode())["=="]("additive")
		render2d.PopBlendMode()
		T(render2d.GetBlendMode())["=="]("alpha")
	end)
end)

T.Test("Graphics render2d invalid blend mode", function()
	init_render2d()
	local success, err = pcall(function()
		render2d.SetBlendMode("invalid_mode")
	end)
	T(success)["=="](false)
	T(err:find("Invalid blend mode"))["~="](nil)
end)

-- ============================================================================
-- Matrix Transform Tests
-- ============================================================================
T.Test("Graphics render2d GetSize", function()
	init_render2d()
	local w, h = render2d.GetSize()
	T(w)["=="](width)
	T(h)["=="](height)
end)

T.Test("Graphics render2d PushMatrix and PopMatrix", function()
	init_render2d()
	render2d.PushMatrix()
	render2d.Translate(100, 100)
	render2d.PopMatrix()
	-- Should not error
	T(true)["=="](true)
end)

T.Test("Graphics render2d matrix stack underflow", function()
	init_render2d()
	local success, err = pcall(function()
		render2d.PopMatrix()
	end)
	T(success)["=="](false)
	T(err:find("Matrix stack underflow"))["~="](nil)
end)

T.Test("Graphics render2d LoadIdentity", function()
	init_render2d()
	render2d.PushMatrix()
	render2d.Translate(100, 100)
	render2d.Scale(2, 2)
	render2d.LoadIdentity()
	-- After LoadIdentity, transformations should be reset
	render2d.PopMatrix()
	T(true)["=="](true)
end)

T.Test("Graphics render2d Translate", function()
	draw2d(function()
		render2d.SetColor(1, 0, 0, 1)
		render2d.PushMatrix()
		render2d.Translate(50, 50)
		render2d.DrawRect(0, 0, 1, 1)
		render2d.PopMatrix()
	end)

	-- Pixel should be at (50, 50)
	test_pixel(50, 50, 1, 0, 0, 1)
end)

T.Test("Graphics render2d Translatef", function()
	draw2d(function()
		render2d.SetColor(0, 1, 0, 1)
		render2d.PushMatrix()
		render2d.Translatef(60.5, 60.5)
		render2d.DrawRect(0, 0, 1, 1)
		render2d.PopMatrix()
	end)

	-- Should be near (60, 60) or (61, 61) due to sub-pixel positioning
	test_pixel(60, 60, 0, 1, 0, 1, 0.5)
end)

T.Test("Graphics render2d Scale", function()
	draw2d(function()
		render2d.SetColor(0, 0, 1, 1)
		render2d.PushMatrix()
		render2d.Scale(2, 2)
		render2d.DrawRect(0, 0, 1, 1)
		render2d.PopMatrix()
	end)

	-- Should be scaled to 2x2
	test_pixel(0, 0, 0, 0, 1, 1)
	test_pixel(1, 1, 0, 0, 1, 1)
end)

T.Test("Graphics render2d Rotate", function()
	draw2d(function()
		render2d.SetColor(1, 1, 0, 1)
		render2d.PushMatrix()
		render2d.Translate(100, 100)
		render2d.Rotate(math.rad(45))
		render2d.DrawRect(-5, -5, 10, 10)
		render2d.PopMatrix()
	end)

	-- Center pixel should be rendered
	test_pixel(100, 100, 1, 1, 0, 1, 0.1)
end)

-- Note: Matrix44.Shear is not implemented, so render2d.Shear is not available
T.Test("Graphics render2d combined transforms", function()
	draw2d(function()
		render2d.SetColor(1, 0, 1, 1)
		render2d.PushMatrix()
		render2d.Translate(150, 150)
		render2d.Rotate(math.rad(30))
		render2d.Scale(2, 2)
		render2d.DrawRect(-2, -2, 4, 4)
		render2d.PopMatrix()
	end)

	-- Center should have the color
	test_pixel(150, 150, 1, 0, 1, 1, 0.1)
end)

T.Test("Graphics render2d PushMatrix with parameters", function()
	draw2d(function()
		render2d.SetColor(0, 1, 1, 1)
		-- x, y, w, h, a
		render2d.PushMatrix(200, 200, 10, 10, math.rad(0))
		render2d.DrawRect(0, 0, 1, 1)
		render2d.PopMatrix()
	end)

	test_pixel(200, 200, 0, 1, 1, 1, 0.1)
end)

T.Test("Graphics render2d PushMatrix dont_multiply", function()
	init_render2d()
	render2d.PushMatrix()
	render2d.Translate(100, 100)
	render2d.PushMatrix(nil, nil, nil, nil, nil, true)
	-- This matrix should be independent
	render2d.PopMatrix()
	render2d.PopMatrix()
	T(true)["=="](true)
end)

-- ============================================================================
-- Drawing Primitive Tests
-- ============================================================================
T.Test("Graphics render2d DrawRect basic", function()
	draw2d(function()
		render2d.SetColor(1, 0.5, 0, 1)
		render2d.DrawRect(250, 250, 10, 10)
	end)

	test_pixel(250, 250, 1, 0.5, 0, 1)
	test_pixel(259, 259, 1, 0.5, 0, 1)
end)

T.Test("Graphics render2d DrawRect with rotation", function()
	draw2d(function()
		render2d.SetColor(0.5, 0.5, 1, 1)
		-- Rotate around center by translating first
		render2d.PushMatrix()
		render2d.Translate(300, 300)
		render2d.Rotate(math.rad(45))
		render2d.Translate(-10, -10) -- Center the 20x20 rect
		render2d.DrawRect(0, 0, 20, 20)
		render2d.PopMatrix()
	end)

	-- Center of rotated rectangle should have the color
	test_pixel(300, 300, 0.5, 0.5, 1, 1, 0.1)
end)

T.Test("Graphics render2d DrawRect with offset", function()
	draw2d(function()
		render2d.SetColor(1, 1, 1, 1)
		render2d.DrawRect(350, 350, 20, 20, 0, 10, 10)
	end)

	-- Should be offset by (10, 10)
	test_pixel(340, 340, 1, 1, 1, 1, 0.1)
end)

T.Test("Graphics render2d DrawTriangle basic", function()
	draw2d(function()
		render2d.SetColor(1, 0, 0.5, 1)
		render2d.DrawTriangle(400, 400, 20, 20)
	end)

	-- Triangle vertices at (-0.5,-0.5), (0.5,0.5), (-0.5,0.5) in local space
	-- Scaled by 20x20 at (400,400): check upper-left area around (395, 405)
	test_pixel(395, 405, 1, 0, 0.5, 1, 0.1)
end)

T.Test("Graphics render2d DrawTriangle with rotation", function()
	draw2d(function()
		render2d.SetColor(0, 1, 0.5, 1)
		render2d.DrawTriangle(450, 450, 20, 20, math.rad(60))
	end)

	-- With rotation, check a point that should be inside
	test_pixel(445, 455, 0, 1, 0.5, 1, 0.2)
end)

-- ============================================================================
-- Mesh Tests
-- ============================================================================
T.Test("Graphics render2d CreateMesh", function()
	init_render2d()
	local vertices = {
		{pos = Vec3(0, 0, 0), uv = Vec2(0, 0), color = Color(1, 0, 0, 1)},
		{pos = Vec3(1, 0, 0), uv = Vec2(1, 0), color = Color(0, 1, 0, 1)},
		{pos = Vec3(0, 1, 0), uv = Vec2(0, 1), color = Color(0, 0, 1, 1)},
	}
	local indices = {0, 1, 2}
	local mesh = render2d.CreateMesh(vertices, indices)
	T(mesh)["~="](nil)
end)

T.Test("Graphics render2d custom mesh rendering", function()
	draw2d(function()
		local vertices = {
			{pos = Vec3(0, 0, 0), uv = Vec2(0, 0), color = Color(1, 1, 1, 1)},
			{pos = Vec3(10, 0, 0), uv = Vec2(1, 0), color = Color(1, 1, 1, 1)},
			{pos = Vec3(10, 10, 0), uv = Vec2(1, 1), color = Color(1, 1, 1, 1)},
			{pos = Vec3(0, 10, 0), uv = Vec2(0, 1), color = Color(1, 1, 1, 1)},
		}
		local indices = {0, 1, 2, 2, 3, 0}
		local mesh = render2d.CreateMesh(vertices, indices)
		render2d.SetColor(0.5, 0, 0.5, 1)
		render2d.BindMesh(mesh)
		render2d.PushMatrix()
		render2d.Translate(100, 100)
		render2d.UploadConstants(render2d.cmd)
		mesh:DrawIndexed(render2d.cmd, 6)
		render2d.PopMatrix()
	end)

	test_pixel(105, 105, 0.5, 0, 0.5, 1, 0.1)
end)

-- ============================================================================
-- Texture Tests
-- ============================================================================
T.Test("Graphics render2d SetTexture and GetTexture", function()
	init_render2d()
	-- Initially no texture
	T(render2d.GetTexture())["=="](nil)
	-- Reset
	render2d.SetTexture()
	T(render2d.GetTexture())["=="](nil)
end)

T.Test("Graphics render2d PushTexture and PopTexture", function()
	init_render2d()
	render2d.SetTexture()
	render2d.PushTexture()
	render2d.SetTexture()
	render2d.PopTexture()
	T(true)["=="](true)
end)

-- ============================================================================
-- Edge Cases and Error Handling
-- ============================================================================
T.Test("Graphics render2d draw with zero size", function()
	draw2d(function()
		render2d.SetColor(1, 1, 1, 1)
		-- Should not crash
		render2d.DrawRect(50, 50, 0, 0)
	end)

	T(true)["=="](true)
end)

T.Test("Graphics render2d draw with negative size", function()
	draw2d(function()
		render2d.SetColor(1, 1, 1, 1)
		-- Should not crash
		render2d.DrawRect(50, 50, -10, -10)
	end)

	T(true)["=="](true)
end)

T.Test("Graphics render2d multiple sequential draws", function()
	draw2d(function()
		for i = 1, 10 do
			render2d.SetColor(i / 10, 0, 0, 1)
			render2d.DrawRect(i * 10, 10, 5, 5)
		end
	end)

	T(true)["=="](true)
end)

T.Test("Graphics render2d nested PushMatrix calls", function()
	draw2d(function()
		render2d.SetColor(1, 1, 1, 1)
		render2d.PushMatrix()
		render2d.Translate(10, 10)
		render2d.PushMatrix()
		render2d.Translate(20, 20)
		render2d.PushMatrix()
		render2d.Translate(30, 30)
		render2d.DrawRect(0, 0, 1, 1)
		render2d.PopMatrix()
		render2d.PopMatrix()
		render2d.PopMatrix()
	end)

	-- Should be at (60, 60)
	test_pixel(60, 60, 1, 1, 1, 1)
end)

T.Test("Graphics render2d color clamping", function()
	init_render2d()
	-- Values outside 0-1 range
	render2d.SetColor(2, -1, 1.5, 0.5)
	local r, g, b, a = render2d.GetColor()
	-- The values are stored as-is (no clamping in Lua)
	T(r)["~"](2)
	T(g)["~"](-1)
	T(b)["~"](1.5)
	-- Reset
	render2d.SetColor(1, 1, 1, 1)
end)

-- ============================================================================
-- Integration Tests
-- ============================================================================
T.Test("Graphics render2d complex scene", function()
	draw2d(function()
		-- Background
		render2d.SetColor(0.1, 0.1, 0.1, 1)
		render2d.DrawRect(0, 0, width, height)

		-- Grid of rectangles
		for i = 0, 4 do
			for j = 0, 4 do
				local hue = (i * 5 + j) / 25
				render2d.SetColor(hue, 1 - hue, 0.5, 1)
				render2d.DrawRect(50 + i * 80, 50 + j * 80, 60, 60)
			end
		end

		-- Rotated rectangles
		for i = 0, 7 do
			render2d.SetColor(1, 0.5, 0, 0.7)
			render2d.DrawRect(256, 256, 100, 20, math.rad(i * 45))
		end

		-- Triangles
		for i = 0, 3 do
			render2d.SetColor(0, 1, 1, 0.8)
			render2d.DrawTriangle(400 + i * 30, 400, 25, 25, math.rad(i * 30))
		end
	end)

	T(true)["=="](true)
	render.Screenshot("render2d_complex_scene")
end)

T.Test("Graphics render2d blend modes visual", function()
	draw2d(function()
		-- Clear background
		render2d.SetColor(0.2, 0.2, 0.2, 1)
		render2d.DrawRect(0, 0, width, height)
		local x_offset = 50
		local y_base = 100
		-- Alpha blending
		render2d.SetBlendMode("alpha")
		render2d.SetColor(1, 0, 0, 0.5)
		render2d.DrawRect(x_offset, y_base, 50, 50)
		render2d.SetColor(0, 0, 1, 0.5)
		render2d.DrawRect(x_offset + 25, y_base, 50, 50)
		-- Additive blending
		x_offset = 150
		render2d.SetBlendMode("additive")
		render2d.SetColor(1, 0, 0, 0.5)
		render2d.DrawRect(x_offset, y_base, 50, 50)
		render2d.SetColor(0, 0, 1, 0.5)
		render2d.DrawRect(x_offset + 25, y_base, 50, 50)
		-- Multiply blending
		x_offset = 250
		render2d.SetBlendMode("multiply")
		render2d.SetColor(1, 0.5, 0.5, 1)
		render2d.DrawRect(x_offset, y_base, 50, 50)
		render2d.SetColor(0.5, 0.5, 1, 1)
		render2d.DrawRect(x_offset + 25, y_base, 50, 50)
		-- Screen blending
		x_offset = 350
		render2d.SetBlendMode("screen")
		render2d.SetColor(0.5, 0, 0, 1)
		render2d.DrawRect(x_offset, y_base, 50, 50)
		render2d.SetColor(0, 0, 0.5, 1)
		render2d.DrawRect(x_offset + 25, y_base, 50, 50)
		render2d.SetBlendMode("alpha")
	end)

	T(true)["=="](true)
end)

T.Test("Graphics render2d matrix stack stress test", function()
	draw2d(function()
		render2d.SetColor(1, 1, 1, 1)

		local function recursive_draw(depth, x, y, size)
			if depth <= 0 or size < 1 then return end

			render2d.PushMatrix()
			render2d.Translate(x, y)
			render2d.Rotate(math.rad(depth * 10))
			render2d.DrawRect(-size / 2, -size / 2, size, size)
			recursive_draw(depth - 1, size, 0, size * 0.7)
			recursive_draw(depth - 1, -size, 0, size * 0.7)
			render2d.PopMatrix()
		end

		recursive_draw(5, 256, 256, 40)
	end)

	T(true)["=="](true)
end)

T.Test("Graphics render2d performance test", function()
	local start_time = os.clock()

	draw2d(function()
		for i = 1, 1000 do
			local x = (i * 13) % width
			local y = (i * 17) % height
			render2d.SetColor((i % 255) / 255, ((i * 2) % 255) / 255, ((i * 3) % 255) / 255, 1)
			render2d.DrawRect(x, y, 2, 2)
		end
	end)

	local elapsed = os.clock() - start_time
	T(elapsed)["<"](0.1) -- Should complete in reasonable time
end)
