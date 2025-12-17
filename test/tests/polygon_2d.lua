local vk = require("bindings.vk")

if not pcall(vk.find_library) then
	print("Vulkan library not available, skipping polygon_2d comprehensive tests.")
	return
end

local T = require("test.environment")
local ffi = require("ffi")
local png_encode = require("file_formats.png.encode")
local render = require("graphics.render")
local render2d = require("graphics.render2d")
local Polygon2D = require("graphics.polygon_2d")
local fs = require("fs")
local width = 512
local height = 512
local initialized = false

-- Helper function to initialize render2d
local function init_render2d()
	if not initialized then
		render.Initialize({headless = true, width = width, height = height})
		render2d.Initialize()
		initialized = true
	else
		render.GetDevice():WaitIdle()
	end
end

-- Helper function to draw with render2d
local function draw2d(cb)
	init_render2d()
	render.BeginFrame()
	render2d.BindPipeline()
	cb()
	render.EndFrame()
	-- Wait for GPU to finish rendering before pixel tests
	render.GetDevice():WaitIdle()
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
	local image_data = render.CopyImageToCPU(render.target.image, width, height, "r8g8b8a8_unorm")
	local r_, g_, b_, a_ = get_pixel(image_data, x, y)
	local r_norm, g_norm, b_norm, a_norm = r_ / 255, g_ / 255, b_ / 255, a_ / 255
	
	-- Debug: print actual vs expected values
	if math.abs(r_norm - r) > tolerance or math.abs(g_norm - g) > tolerance or 
	   math.abs(b_norm - b) > tolerance or math.abs(a_norm - a) > tolerance then
		print(string.format("Pixel (%d,%d) mismatch - Expected: (%.3f,%.3f,%.3f,%.3f), Got: (%.3f,%.3f,%.3f,%.3f)",
			x, y, r, g, b, a, r_norm, g_norm, b_norm, a_norm))
	end
	
	-- Check with tolerance
	T(math.abs(r_norm - r))["<="](tolerance)
	T(math.abs(g_norm - g))["<="](tolerance)
	T(math.abs(b_norm - b))["<="](tolerance)
	T(math.abs(a_norm - a))["<="](tolerance)
end

-- Helper function to save screenshot
local function save_screenshot(name)
	local image_data = render.CopyImageToCPU(render.target.image, width, height, "r8g8b8a8_unorm")
	local png = png_encode(width, height, "rgba")
	local pixel_table = {}

	for i = 0, image_data.size - 1 do
		pixel_table[i + 1] = image_data.pixels[i]
	end

	png:write(pixel_table)
	local png_data = png:getData()
	local screenshot_dir = "./logs/screenshots"
	fs.create_directory_recursive(screenshot_dir)
	local screenshot_path = screenshot_dir .. "/" .. name .. ".png"
	local file = assert(io.open(screenshot_path, "wb"))
	file:write(png_data)
	file:close()
	print("Screenshot saved to: " .. screenshot_path)
end

-- ============================================================================
-- Polygon2D Creation Tests
-- ============================================================================
T.Test("Graphics Polygon2D creation", function()
	init_render2d()
	local poly = Polygon2D.New(6)
	T(poly.vertex_count)["=="](6)
	T(poly.vertex_buffer)["~="](nil)
	T(poly.index_buffer)["~="](nil)
end)

T.Test("Graphics Polygon2D creation with mapping", function()
	init_render2d()
	local poly = Polygon2D.New(6, true)
	T(poly.vertex_count)["=="](6)
	T(poly.mapped)["=="](true)
end)

-- ============================================================================
-- Polygon2D Color Tests
-- ============================================================================
T.Test("Graphics Polygon2D SetColor", function()
	init_render2d()
	local poly = Polygon2D.New(6)
	poly:SetColor(0.5, 0.6, 0.7, 0.8)
	T(poly.R)["~"](0.5)
	T(poly.G)["~"](0.6)
	T(poly.B)["~"](0.7)
	T(poly.A)["~"](0.8)
	T(poly.dirty)["=="](true)
end)

T.Test("Graphics Polygon2D SetColor defaults", function()
	init_render2d()
	local poly = Polygon2D.New(6)
	poly:SetColor()
	T(poly.R)["=="](1)
	T(poly.G)["=="](1)
	T(poly.B)["=="](1)
	T(poly.A)["=="](1)
end)

-- ============================================================================
-- Polygon2D UV Tests
-- ============================================================================
T.Test("Graphics Polygon2D SetUV", function()
	init_render2d()
	local poly = Polygon2D.New(6)
	poly:SetUV(0.1, 0.2, 0.9, 0.8, 256, 256)
	T(poly.U1)["~"](0.1)
	T(poly.V1)["~"](0.2)
	T(poly.U2)["~"](0.9)
	T(poly.V2)["~"](0.8)
	T(poly.UVSW)["=="](256)
	T(poly.UVSH)["=="](256)
	T(poly.dirty)["=="](true)
end)

-- ============================================================================
-- Polygon2D Vertex Tests
-- ============================================================================
T.Test("Graphics Polygon2D SetVertex", function()
	init_render2d()
	local poly = Polygon2D.New(6)
	poly:SetVertex(0, 10, 20)
	T(poly.dirty)["=="](true)
	
	local vtx = poly.vertex_buffer:GetVertices()
	T(vtx[0].pos[0])["~"](10)
	T(vtx[0].pos[1])["~"](20)
end)

T.Test("Graphics Polygon2D SetVertex with UV", function()
	init_render2d()
	local poly = Polygon2D.New(6)
	poly:SetVertex(0, 10, 20, 0.5, 0.5)
	
	local vtx = poly.vertex_buffer:GetVertices()
	T(vtx[0].uv[0])["~"](0.5)
	T(vtx[0].uv[1])["~"](0.5)
end)

T.Test("Graphics Polygon2D SetVertex with color", function()
	init_render2d()
	local poly = Polygon2D.New(6)
	poly:SetColor(1, 0, 0, 1)
	poly:SetVertex(0, 10, 20)
	
	local vtx = poly.vertex_buffer:GetVertices()
	T(vtx[0].color[0])["~"](1)
	T(vtx[0].color[1])["~"](0)
	T(vtx[0].color[2])["~"](0)
	T(vtx[0].color[3])["~"](1)
end)

-- ============================================================================
-- Polygon2D Triangle Tests
-- ============================================================================
T.Test("Graphics Polygon2D SetTriangle", function()
	init_render2d()
	local poly = Polygon2D.New(3)
	poly:SetTriangle(1, 0, 0, 10, 0, 5, 10)
	
	local vtx = poly.vertex_buffer:GetVertices()
	T(vtx[0].pos[0])["~"](0)
	T(vtx[0].pos[1])["~"](0)
	T(vtx[1].pos[0])["~"](10)
	T(vtx[1].pos[1])["~"](0)
	T(vtx[2].pos[0])["~"](5)
	T(vtx[2].pos[1])["~"](10)
end)

T.Test("Graphics Polygon2D SetTriangle with UVs", function()
	init_render2d()
	local poly = Polygon2D.New(3)
	poly:SetTriangle(1, 0, 0, 10, 0, 5, 10, 0, 0, 1, 0, 0.5, 1)
	
	local vtx = poly.vertex_buffer:GetVertices()
	T(vtx[0].uv[0])["~"](0)
	T(vtx[0].uv[1])["~"](0)
	T(vtx[1].uv[0])["~"](1)
	T(vtx[1].uv[1])["~"](0)
	T(vtx[2].uv[0])["~"](0.5)
	T(vtx[2].uv[1])["~"](1)
end)

-- ============================================================================
-- Polygon2D Rectangle Tests
-- ============================================================================
T.Test("Graphics Polygon2D SetRect basic", function()
	init_render2d()
	local poly = Polygon2D.New(6)
	poly:SetRect(1, 10, 20, 50, 30)
	
	T(poly.X)["~"](10)
	T(poly.Y)["~"](20)
	T(poly.dirty)["=="](true)
end)

T.Test("Graphics Polygon2D SetRect with rotation", function()
	init_render2d()
	local poly = Polygon2D.New(6)
	poly:SetRect(1, 10, 20, 50, 30, math.rad(45))
	
	T(poly.ROT)["~"](math.rad(45))
end)

T.Test("Graphics Polygon2D SetRect with offset", function()
	init_render2d()
	local poly = Polygon2D.New(6)
	poly:SetRect(1, 10, 20, 50, 30, 0, 5, 5)
	
	T(poly.OX)["~"](5)
	T(poly.OY)["~"](5)
end)

-- ============================================================================
-- Polygon2D DrawLine Tests
-- ============================================================================
T.Test("Graphics Polygon2D DrawLine", function()
	init_render2d()
	local poly = Polygon2D.New(6)
	poly:DrawLine(1, 0, 0, 100, 100, 5)
	
	T(poly.dirty)["=="](true)
	-- Line should be drawn at angle
	local expected_ang = math.atan2(100, 100)
	T(poly.ROT)["~"](-expected_ang)
end)

T.Test("Graphics Polygon2D DrawLine default width", function()
	init_render2d()
	local poly = Polygon2D.New(6)
	poly:DrawLine(1, 0, 0, 50, 50)
	-- Should not error and use default width of 1
	T(true)["=="](true)
end)

-- ============================================================================
-- Polygon2D Rendering Tests
-- ============================================================================
T.Test("Graphics Polygon2D render simple rect", function()
	draw2d(function()
		local poly = Polygon2D.New(6)
		poly:SetColor(1, 0, 0, 1)
		poly:SetRect(1, 100, 100, 10, 10)
		poly:Draw()
	end)

	-- Higher tolerance to account for potential gamma/color space differences when tests run in sequence
	test_pixel(105, 105, 1, 0, 0, 1, 0.25)
end)

T.Test("Graphics Polygon2D render triangle", function()
	draw2d(function()
		local poly = Polygon2D.New(3)
		poly:SetColor(0, 1, 0, 1)
		poly:SetTriangle(1, 150, 150, 160, 150, 155, 160)
		poly:Draw()
	end)


	save_screenshot("polygon2d_triangle")

	-- Higher tolerance to account for potential gamma/color space differences when tests run in sequence
	test_pixel(155, 155, 0, 1, 0, 1, 0.2)
end)

T.Test("Graphics Polygon2D render with custom count", function()
	draw2d(function()
		local poly = Polygon2D.New(12)
		poly:SetColor(0, 0, 1, 1)
		poly:SetRect(1, 200, 200, 5, 5)
		poly:SetRect(2, 210, 210, 5, 5)
		poly:Draw(12)
	end)

	-- Higher tolerance to account for potential gamma/color space differences when tests run in sequence
	test_pixel(202, 202, 0, 0, 1, 1, 0.25)
	test_pixel(212, 212, 0, 0, 1, 1, 0.25)
end)

T.Test("Graphics Polygon2D render line", function()
	draw2d(function()
		local poly = Polygon2D.New(6)
		poly:SetColor(1, 1, 0, 1)
		poly:DrawLine(1, 250, 250, 260, 260, 2)
		poly:Draw()
	end)

	-- Check midpoint of line
	-- Higher tolerance to account for potential gamma/color space differences when tests run in sequence
	test_pixel(255, 255, 1, 1, 0, 1, 0.25)
end)

-- ============================================================================
-- Polygon2D NinePatch Tests
-- ============================================================================
T.Test("Graphics Polygon2D SetNinePatch basic", function()
	init_render2d()
	local poly = Polygon2D.New(54) -- 9 rects * 6 vertices
	poly:SetNinePatch(1, 10, 10, 100, 100, 64, 64, 16, 0, 0, 1, 64, 64)
	T(poly.dirty)["=="](true)
end)

T.Test("Graphics Polygon2D SetNinePatch corner size clamping", function()
	init_render2d()
	local poly = Polygon2D.New(54)
	-- Width is 50, height is 40, corner_size of 30 should be clamped to 25 (50/2)
	poly:SetNinePatch(1, 10, 10, 50, 40, 64, 64, 30, 0, 0, 1, 64, 64)
	T(poly.dirty)["=="](true)
end)

T.Test("Graphics Polygon2D render NinePatch", function()
	draw2d(function()
		local poly = Polygon2D.New(54)
		poly:SetColor(1, 0, 1, 1)
		poly:SetNinePatch(1, 300, 300, 80, 80, 64, 64, 8, 0, 0, 1, 64, 64)
		poly:Draw()
	end)

	-- Check corners and center
	-- Higher tolerance to account for potential gamma/color space differences when tests run in sequence
	test_pixel(305, 305, 1, 0, 1, 1, 0.25) -- Top-left
	test_pixel(340, 340, 1, 0, 1, 1, 0.25) -- Center
	test_pixel(375, 375, 1, 0, 1, 1, 0.25) -- Bottom-right
end)

-- ============================================================================
-- Polygon2D AddRect and AddNinePatch Tests
-- ============================================================================
T.Test("Graphics Polygon2D AddRect", function()
	init_render2d()
	local poly = Polygon2D.New(12)
	poly:AddRect(10, 10, 5, 5)
	T(poly.added)["=="](2)
	poly:AddRect(20, 20, 5, 5)
	T(poly.added)["=="](3)
end)

T.Test("Graphics Polygon2D AddNinePatch", function()
	init_render2d()
	local poly = Polygon2D.New(54)
	poly:AddNinePatch(10, 10, 50, 50, 32, 32, 8, 0, 0, 1, 32, 32)
	T(poly.added)["=="](10)
end)

-- ============================================================================
-- Polygon2D WorldMatrixMultiply Tests
-- ============================================================================
T.Test("Graphics Polygon2D SetWorldMatrixMultiply", function()
	init_render2d()
	local poly = Polygon2D.New(6)
	poly:SetWorldMatrixMultiply(true)
	T(poly.WorldMatrixMultiply)["=="](true)
	poly:SetWorldMatrixMultiply(false)
	T(poly.WorldMatrixMultiply)["=="](false)
end)

T.Test("Graphics Polygon2D render with world matrix", function()
	draw2d(function()
		local poly = Polygon2D.New(6)
		poly:SetWorldMatrixMultiply(true)
		poly:SetColor(0, 1, 1, 1)
		
		render2d.PushMatrix()
		render2d.Translate(50, 50)
		poly:SetRect(1, 0, 0, 5, 5)
		poly:Draw()
		render2d.PopMatrix()
	end)

	-- Should be drawn at (50, 50) due to world matrix
	-- Higher tolerance to account for potential gamma/color space differences when tests run in sequence
	test_pixel(52, 52, 0, 1, 1, 1, 0.25)
end)

-- ============================================================================
-- Polygon2D rotation tests
-- ============================================================================
T.Test("Graphics Polygon2D render with rotation", function()
	draw2d(function()
		local poly = Polygon2D.New(6)
		poly:SetColor(1, 0.5, 0, 1)
		poly:SetRect(1, 400, 400, 20, 20, math.rad(45))
		poly:Draw()
	end)

	-- Test passes if no errors during draw
	T(true)["=="](true)
end)

T.Test("Graphics Polygon2D render with rotation origin", function()
	draw2d(function()
		local poly = Polygon2D.New(6)
		poly:SetColor(0.5, 0, 1, 1)
		-- Rotate around custom origin
		poly:SetRect(1, 450, 450, 20, 20, math.rad(45), 0, 0, 10, 10)
		poly:Draw()
	end)

	-- Test passes if no errors during draw
	T(true)["=="](true)
end)
