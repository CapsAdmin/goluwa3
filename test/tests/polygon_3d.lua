local vk = require("bindings.vk")

if not pcall(vk.find_library) then
	print("Vulkan library not available, skipping polygon_3d comprehensive tests.")
	return
end

local T = require("test.environment")
local ffi = require("ffi")
local png_encode = require("file_formats.png.encode")
local render = require("graphics.render")
local render3d = require("graphics.render3d")
local Polygon3D = require("graphics.polygon_3d")
local Material = require("graphics.material")
local Vec3 = require("structs.vec3")
local Vec2 = require("structs.vec2")
local Matrix44 = require("structs.matrix").Matrix44
local fs = require("fs")
local width = 512
local height = 512
local initialized = false

-- Helper function to initialize render3d
local function init_render3d()
	if not initialized then
		render.Initialize({headless = true, width = width, height = height})
		initialized = true
	else
		render.GetDevice():WaitIdle()
	end
	
	-- Always call Initialize - it will return early if already initialized
	render3d.Initialize()
end

-- Helper function to draw with render3d
local function draw3d(cb)
	init_render3d()
	
	-- Set up camera with orthographic-like view for predictable testing
	local view_matrix = Matrix44()
	view_matrix:SetTranslation(0, 0, -10)
	render3d.SetViewMatrix(view_matrix)
	render3d.SetCameraViewport(0, 0, width, height)
	render3d.SetCameraFOV(math.pi / 4)
	
	-- Set up basic lighting
	render3d.SetLightDirection(0.5, -1.0, 0.3)
	render3d.SetLightColor(1.0, 1.0, 1.0, 1.0)
	
	render.BeginFrame()
	local cmd = render.GetCommandBuffer()
	local frame_index = render.GetCurrentFrame()
	render3d.pipeline:Bind(cmd, frame_index)
	
	cb(cmd)
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
-- Polygon3D Creation Tests
-- ============================================================================
T.Test("Graphics Polygon3D creation", function()
	init_render3d()
	local poly = Polygon3D.New()
	T(poly)["~="](nil)
	T(poly.Vertices)["~="](nil)
	T(#poly.Vertices)["=="](0)
end)

T.Test("Graphics Polygon3D AddVertex", function()
	init_render3d()
	local poly = Polygon3D.New()
	poly:AddVertex({pos = Vec3(0, 0, 0), uv = Vec2(0, 0)})
	poly:AddVertex({pos = Vec3(1, 0, 0), uv = Vec2(1, 0)})
	poly:AddVertex({pos = Vec3(0, 1, 0), uv = Vec2(0, 1)})
	T(#poly.Vertices)["=="](3)
end)

-- ============================================================================
-- Polygon3D Triangle Tests
-- ============================================================================
T.Test("Graphics Polygon3D simple triangle", function()
	init_render3d()
	local poly = Polygon3D.New()
	
	-- Create a simple triangle
	poly:AddVertex({pos = Vec3(-1, -1, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)})
	poly:AddVertex({pos = Vec3(1, -1, 0), uv = Vec2(1, 0), normal = Vec3(0, 0, 1)})
	poly:AddVertex({pos = Vec3(0, 1, 0), uv = Vec2(0.5, 1), normal = Vec3(0, 0, 1)})
	
	poly:AddSubMesh(3)
	poly:Upload()
	
	T(poly.mesh)["~="](nil)
	T(poly.mesh.vertex_buffer)["~="](nil)
end)

-- ============================================================================
-- Polygon3D Cube Tests
-- ============================================================================
T.Test("Graphics Polygon3D CreateCube", function()
	init_render3d()
	local poly = Polygon3D.New()
	poly:CreateCube(1.0, 1.0)
	
	-- Cube has 6 faces * 6 vertices (2 triangles) = 36 vertices
	T(#poly.Vertices)["=="](36)
end)

T.Test("Graphics Polygon3D CreateCube with different size", function()
	init_render3d()
	local poly = Polygon3D.New()
	poly:CreateCube(2.0, 1.0)
	
	T(#poly.Vertices)["=="](36)
	-- Check first vertex has correct scaled position
	T(math.abs(poly.Vertices[1].pos.x))["~"](2.0)
end)

-- ============================================================================
-- Polygon3D SubMesh Tests
-- ============================================================================
T.Test("Graphics Polygon3D AddSubMesh with count", function()
	init_render3d()
	local poly = Polygon3D.New()
	poly:AddVertex({pos = Vec3(0, 0, 0)})
	poly:AddVertex({pos = Vec3(1, 0, 0)})
	poly:AddVertex({pos = Vec3(0, 1, 0)})
	poly:AddSubMesh(3)
	
	T(#poly.sub_meshes)["=="](1)
	T(#poly.sub_meshes[1].indices)["=="](3)
end)

T.Test("Graphics Polygon3D GetSubMeshes", function()
	init_render3d()
	local poly = Polygon3D.New()
	poly:AddVertex({pos = Vec3(0, 0, 0)})
	poly:AddVertex({pos = Vec3(1, 0, 0)})
	poly:AddVertex({pos = Vec3(0, 1, 0)})
	poly:AddSubMesh(3)
	
	local submeshes = poly:GetSubMeshes()
	T(#submeshes)["=="](1)
end)

-- ============================================================================
-- Polygon3D Normal Tests
-- ============================================================================
T.Test("Graphics Polygon3D BuildNormals", function()
	init_render3d()
	local poly = Polygon3D.New()
	
	-- Create triangle without normals
	poly:AddVertex({pos = Vec3(0, 0, 0), uv = Vec2(0, 0)})
	poly:AddVertex({pos = Vec3(1, 0, 0), uv = Vec2(1, 0)})
	poly:AddVertex({pos = Vec3(0, 1, 0), uv = Vec2(0, 1)})
	poly:AddSubMesh(3)
	
	poly:BuildNormals()
	
	-- Check that normals were generated
	T(poly.Vertices[1].normal)["~="](nil)
	T(poly.Vertices[2].normal)["~="](nil)
	T(poly.Vertices[3].normal)["~="](nil)
end)

-- ============================================================================
-- Polygon3D Upload and Mesh Tests
-- ============================================================================
T.Test("Graphics Polygon3D Upload creates mesh", function()
	init_render3d()
	local poly = Polygon3D.New()
	
	poly:AddVertex({pos = Vec3(0, 0, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)})
	poly:AddVertex({pos = Vec3(1, 0, 0), uv = Vec2(1, 0), normal = Vec3(0, 0, 1)})
	poly:AddVertex({pos = Vec3(0, 1, 0), uv = Vec2(0, 1), normal = Vec3(0, 0, 1)})
	poly:AddSubMesh(3)
	
	poly:Upload()
	
	T(poly.mesh)["~="](nil)
	T(poly.mesh.vertex_buffer)["~="](nil)
end)

T.Test("Graphics Polygon3D Upload with no vertices", function()
	init_render3d()
	local poly = Polygon3D.New()
	poly:Upload()
	
	-- Should not create mesh with no vertices
	T(poly.mesh)["=="](nil)
end)

-- ============================================================================
-- Polygon3D Rendering Tests
-- ============================================================================
T.Test("Graphics Polygon3D render simple triangle", function()
	draw3d(function(cmd)
		local poly = Polygon3D.New()
		
		-- Create a triangle facing camera
		poly:AddVertex({pos = Vec3(-0.5, -0.5, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)})
		poly:AddVertex({pos = Vec3(0.5, -0.5, 0), uv = Vec2(1, 0), normal = Vec3(0, 0, 1)})
		poly:AddVertex({pos = Vec3(0, 0.5, 0), uv = Vec2(0.5, 1), normal = Vec3(0, 0, 1)})
		
		poly:AddSubMesh(3)
		poly:BuildNormals()
		poly:Upload()
		
		-- Set material with a base color
		local mat = Material.New({base_color_factor = {1.0, 0.0, 0.0, 1.0}})
		render3d.SetMaterial(mat)
		render3d.UploadConstants(cmd)
		
		poly:Draw(cmd)
	end)
	
	-- Test passes if no errors during draw
	T(true)["=="](true)
end)

T.Test("Graphics Polygon3D render cube", function()
	draw3d(function(cmd)
		local poly = Polygon3D.New()
		poly:CreateCube(0.5, 1.0)
		poly:AddSubMesh(#poly.Vertices)
		poly:BuildNormals()
		poly:Upload()
		
		-- Set material with green color
		local mat = Material.New({base_color_factor = {0.0, 1.0, 0.0, 1.0}})
		render3d.SetMaterial(mat)
		render3d.UploadConstants(cmd)
		
		poly:Draw(cmd)
	end)
	
	-- Test passes if no errors during draw
	T(true)["=="](true)
end)

T.Test("Graphics Polygon3D render with world matrix", function()
	draw3d(function(cmd)
		local poly = Polygon3D.New()
		
		-- Small triangle
		poly:AddVertex({pos = Vec3(-0.3, -0.3, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)})
		poly:AddVertex({pos = Vec3(0.3, -0.3, 0), uv = Vec2(1, 0), normal = Vec3(0, 0, 1)})
		poly:AddVertex({pos = Vec3(0, 0.3, 0), uv = Vec2(0.5, 1), normal = Vec3(0, 0, 1)})
		
		poly:AddSubMesh(3)
		poly:BuildNormals()
		poly:Upload()
		
		-- Apply world matrix transformation
		local world = Matrix44()
		world:SetTranslation(1, 0, 0)
		render3d.SetWorldMatrix(world)
		
		local mat = Material.New({base_color_factor = {0.0, 0.0, 1.0, 1.0}})
		render3d.SetMaterial(mat)
		render3d.UploadConstants(cmd)
		
		poly:Draw(cmd)
		
		-- Reset world matrix
		render3d.SetWorldMatrix(Matrix44())
	end)
	
	T(true)["=="](true)
end)

T.Test("Graphics Polygon3D render multiple objects", function()
	draw3d(function(cmd)
		-- First triangle
		local poly1 = Polygon3D.New()
		poly1:AddVertex({pos = Vec3(-0.8, -0.5, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)})
		poly1:AddVertex({pos = Vec3(-0.4, -0.5, 0), uv = Vec2(1, 0), normal = Vec3(0, 0, 1)})
		poly1:AddVertex({pos = Vec3(-0.6, -0.1, 0), uv = Vec2(0.5, 1), normal = Vec3(0, 0, 1)})
		poly1:AddSubMesh(3)
		poly1:BuildNormals()
		poly1:Upload()
		
		-- Second triangle
		local poly2 = Polygon3D.New()
		poly2:AddVertex({pos = Vec3(0.4, 0.1, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)})
		poly2:AddVertex({pos = Vec3(0.8, 0.1, 0), uv = Vec2(1, 0), normal = Vec3(0, 0, 1)})
		poly2:AddVertex({pos = Vec3(0.6, 0.5, 0), uv = Vec2(0.5, 1), normal = Vec3(0, 0, 1)})
		poly2:AddSubMesh(3)
		poly2:BuildNormals()
		poly2:Upload()
		
		-- Draw first with red material
		local mat1 = Material.New({base_color_factor = {1.0, 0.0, 0.0, 1.0}})
		render3d.SetMaterial(mat1)
		render3d.UploadConstants(cmd)
		poly1:Draw(cmd)
		
		-- Draw second with blue material
		local mat2 = Material.New({base_color_factor = {0.0, 0.0, 1.0, 1.0}})
		render3d.SetMaterial(mat2)
		render3d.UploadConstants(cmd)
		poly2:Draw(cmd)
	end)
	
	T(true)["=="](true)
end)

T.Test("Graphics Polygon3D render cube screenshot", function()
	draw3d(function(cmd)
		-- Create a rotated cube for visual testing
		local poly = Polygon3D.New()
		poly:CreateCube(0.7, 1.0)
		poly:AddSubMesh(#poly.Vertices)
		poly:BuildNormals()
		poly:Upload()
		
		-- Apply rotation
		local world = Matrix44()
		world:Rotate(math.rad(25), 1, 0, 0)
		world:Rotate(math.rad(35), 0, 1, 0)
		render3d.SetWorldMatrix(world)
		
		-- Yellow material
		local mat = Material.New({base_color_factor = {1.0, 1.0, 0.0, 1.0}})
		render3d.SetMaterial(mat)
		render3d.UploadConstants(cmd)
		
		poly:Draw(cmd)
		render3d.SetWorldMatrix(Matrix44())
	end)
	
	save_screenshot("polygon_3d_cube_test")
	T(true)["=="](true)
end)

-- ============================================================================
-- Polygon3D Clear Tests
-- ============================================================================
T.Test("Graphics Polygon3D Clear", function()
	init_render3d()
	local poly = Polygon3D.New()
	poly:AddVertex({pos = Vec3(0, 0, 0)})
	poly:AddVertex({pos = Vec3(1, 0, 0)})
	poly:AddVertex({pos = Vec3(0, 1, 0)})
	
	T(#poly.Vertices)["=="](3)
	
	poly:Clear()
	T(#poly.Vertices)["=="](0)
	T(poly.i)["=="](1)
end)

-- ============================================================================
-- Polygon3D AABB Tests
-- ============================================================================
T.Test("Graphics Polygon3D BuildBoundingBox", function()
	init_render3d()
	local poly = Polygon3D.New()
	
	poly:AddVertex({pos = Vec3(-1, -1, -1)})
	poly:AddVertex({pos = Vec3(1, 1, 1)})
	poly:AddVertex({pos = Vec3(0, 0, 0)})
	poly:AddSubMesh(3)
	
	poly:BuildBoundingBox()
	
	-- AABB should have been expanded
	T(poly.AABB)["~="](nil)
end)
