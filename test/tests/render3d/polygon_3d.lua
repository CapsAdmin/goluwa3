local vk = require("bindings.vk")

if not pcall(vk.find_library) then
	print("Vulkan library not available, skipping polygon_3d comprehensive tests.")
	return
end

local T = require("test.environment")
local ffi = require("ffi")
local event = require("event")
local render = require("render.render")
local render3d = require("render3d.render3d")
local Polygon3D = require("render3d.polygon_3d")
local Material = require("render3d.material")
local Vec3 = require("structs.vec3")
local Quat = require("structs.quat")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Rect = require("structs.rect")
local ecs = require("ecs")
require("components.transform")
local Matrix44 = require("structs.matrix44")
local fs = require("fs")
local width = 512
local height = 512

-- Helper function to initialize render3d
local function init_render3d()
	render.Initialize({headless = true, width = width, height = height})
	render3d.Initialize()
end

local function draw3d(cb)
	init_render3d()
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 0, -10))
	cam:SetViewport(Rect(0, 0, width, height))
	cam:SetFOV(math.rad(45))
	ecs.CreateFromTable(
		{
			transform = {
				Rotation = Quat(0, 0, 0, -1):Normalize(),
			},
			light = {
				LightType = "sun",
				Color = Color(1, 1, 1),
				Intensity = 1,
			},
		}
	)
	local draw_listener = event.AddListener("Draw3DGeometry", "test_draw", function(cmd)
		cb(cmd)
	end)
	render.BeginFrame()
	event.Call("Draw", render.GetCommandBuffer(), 0)
	render.EndFrame()
	event.RemoveListener("Draw3DGeometry", "test_draw")
	render.GetDevice():WaitIdle()
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
	-- XY plane triangle, facing +Z
	poly:AddVertex({pos = Vec3(0, 0, 0), uv = Vec2(0, 0)})
	poly:AddVertex({pos = Vec3(1, 0, 0), uv = Vec2(1, 0)})
	poly:AddVertex({pos = Vec3(0, 1, 0), uv = Vec2(0, 1)})
	poly:AddSubMesh(3)
	poly:BuildNormals()

	-- Check that normals were generated correctly
	-- (1,0,0) x (0,1,0) = (0,0,1)
	for i = 1, 3 do
		local n = poly.Vertices[i].normal
		T(n)["~="](nil)
		T(n.x)["~"](0)
		T(n.y)["~"](0)
		T(n.z)["~"](1)
	end
end)

T.Test("Graphics Polygon3D BuildTangents", function()
	init_render3d()
	local poly = Polygon3D.New()
	-- Create triangle without tangents
	-- Pos: (0,0,0), (1,0,0), (0,1,0)
	-- UV:  (0,0),   (1,0),   (0,1)
	poly:AddVertex({pos = Vec3(0, 0, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)})
	poly:AddVertex({pos = Vec3(1, 0, 0), uv = Vec2(1, 0), normal = Vec3(0, 0, 1)})
	poly:AddVertex({pos = Vec3(0, 1, 0), uv = Vec2(0, 1), normal = Vec3(0, 0, 1)})
	poly:AddSubMesh(3)
	poly:BuildTangents()

	-- Check that tangents were generated correctly
	-- Tangent should be in the direction of +U (which is +X in this case)
	for i = 1, 3 do
		local t = poly.Vertices[i].tangent
		T(t)["~="](nil)
		T(t.x)["~"](1)
		T(t.y)["~"](0)
		T(t.z)["~"](0)
	end
end)

T.Test("Graphics Polygon3D BuildNormals and Tangents YZ plane", function()
	init_render3d()
	local poly = Polygon3D.New()
	-- YZ plane triangle, facing +X
	-- Pos: (0,0,0), (0,1,0), (0,0,1)
	-- UVs: (0,0), (1,0), (0,1)
	poly:AddVertex({pos = Vec3(0, 0, 0), uv = Vec2(0, 0)})
	poly:AddVertex({pos = Vec3(0, 1, 0), uv = Vec2(1, 0)})
	poly:AddVertex({pos = Vec3(0, 0, 1), uv = Vec2(0, 1)})
	poly:AddSubMesh(3)
	poly:BuildNormals()
	poly:BuildTangents()

	for i = 1, 3 do
		local n = poly.Vertices[i].normal
		T(n)["~="](nil)
		T(n.x)["~"](1)
		T(n.y)["~"](0)
		T(n.z)["~"](0)
		local t = poly.Vertices[i].tangent
		T(t)["~="](nil)
		T(t.x)["~"](0)
		T(t.y)["~"](1)
		T(t.z)["~"](0)
	end
end)

T.Test("Graphics Polygon3D BuildTangents zero UV area", function()
	init_render3d()
	local poly = Polygon3D.New()
	-- Degenerate UVs
	poly:AddVertex({pos = Vec3(0, 0, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)})
	poly:AddVertex({pos = Vec3(1, 0, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)})
	poly:AddVertex({pos = Vec3(0, 1, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)})
	poly:AddSubMesh(3)
	poly:BuildTangents()

	-- Should not crash and should produce some tangent
	for i = 1, 3 do
		T(poly.Vertices[i].tangent)["~="](nil)
	end
end)

T.Test("Graphics Polygon3D LoadHeightmap", function()
	init_render3d()
	local poly = Polygon3D.New()
	-- Mock texture
	local mock_tex = {
		GetSize = function()
			return Vec2(2, 2)
		end,
		GetRawPixelColor = function(self, x, y)
			-- Return 255 for (0,0), 0 otherwise
			if math.floor(x) == 0 and math.floor(y) == 0 then
				return 255, 255, 255, 255
			end

			return 0, 0, 0, 255
		end,
	}
	local size = Vec2(10, 10)
	local res = Vec2(2, 2)
	local height = 10
	poly:LoadHeightmap(mock_tex, size, res, Vec2(1, 1), height)
	-- 2x2 resolution means 4 cells
	-- Each cell has 4 triangles = 12 vertices
	-- Total 4 * 12 = 48 vertices
	T(#poly.Vertices)["=="](48)
	-- Check a few vertices to ensure height is applied
	-- The first cell (0,0) uses x2=0, y2=0 in get_color
	-- get_color(0,0) should be 1.0, so height is 10.
	-- The vertices for the first cell should have some Z values around 10
	local found_height = false

	for _, v in ipairs(poly.Vertices) do
		if math.abs(v.pos.y - (10 - 5)) < 0.001 or math.abs(v.pos.y - (0 - 5)) < 0.001 then

		-- offset.y is height/2 = 5. So heights are relative to -5.
		-- Wait, offset = -Vec3(size.x, height, size.y) / 2
		-- For height=10, size=10, offset = -Vec3(10, 10, 10) / 2 = Vec3(-5, -5, -5)
		-- z = get_color(...) * height
		-- pos = Vec3(wx, z, wz) + offset
		-- If get_color is 1, pos.y = 10 - 5 = 5
		-- If get_color is 0, pos.y = 0 - 5 = -5
		end

		if math.abs(v.pos.y - 5) < 0.001 then found_height = true end
	end

	T(found_height)["=="](true)
end)

T.Test("Graphics Polygon3D LoadHeightmap with pow", function()
	init_render3d()
	local poly = Polygon3D.New()
	-- Mock texture
	local mock_tex = {
		GetSize = function()
			return Vec2(2, 2)
		end,
		GetRawPixelColor = function(self, x, y)
			-- Return 128 (approx 0.5)
			return 128, 128, 128, 255
		end,
	}
	local size = Vec2(10, 10)
	local res = Vec2(1, 1)
	local height = 10
	local pow = 2
	-- get_color = ((128+128+128+255)/4 / 255) ^ 2
	-- (159.75 / 255) ^ 2 approx 0.39246
	-- expected_val = 0.39246 * 10 - 5 = -1.0754
	poly:LoadHeightmap(mock_tex, size, res, Vec2(1, 1), height, pow)
	local found_expected_y = false
	local expected_val = (((128 + 128 + 128 + 255) / 4) / 255) ^ pow * height - (height / 2)

	for _, v in ipairs(poly.Vertices) do
		if math.abs(v.pos.y - expected_val) < 0.01 then found_expected_y = true end
	end

	T(found_expected_y)["=="](true)
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
		local mat = Material.New():SetColorMultiplier(Color(1.0, 0.0, 0.0, 1.0))
		render3d.SetMaterial(mat)
		render3d.UploadGBufferConstants(cmd)
		poly:Draw(cmd)
	end)

	-- Test passes if no errors during draw
	T(true)["=="](true)
end)

local function setup_view()
	local Quat = require("structs.quat")
	render3d.GetCamera():SetPosition(Vec3(2, 2 + 1, 2))
	render3d.GetCamera():SetRotation(Quat():SetAngles(Deg3(-45, 45, 0)))
end

T.Test("Graphics Polygon3D render cube", function()
	draw3d(function(cmd)
		setup_view()
		local poly = Polygon3D.New()
		poly:CreateCube(0.5, 1.0)
		poly:AddSubMesh(#poly.Vertices)
		poly:BuildNormals()
		poly:Upload()
		-- Set material with green color
		local mat = Material.New():SetColorMultiplier(Color(0.0, 1.0, 0.0, 1.0))
		render3d.SetMaterial(mat)
		render3d.UploadGBufferConstants(cmd)
		poly:Draw(cmd)
	end)
end)

T.Test("Graphics Polygon3D render with world matrix", function()
	draw3d(function(cmd)
		setup_view()
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
		local mat = Material.New():SetColorMultiplier(Color(0.0, 0.0, 1.0, 1.0))
		render3d.SetMaterial(mat)
		render3d.UploadGBufferConstants(cmd)
		poly:Draw(cmd)
		-- Reset world matrix
		render3d.SetWorldMatrix(Matrix44())
	end)
end)

T.Test("Graphics Polygon3D render multiple objects", function()
	draw3d(function(cmd)
		setup_view()
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
		local mat1 = Material.New():SetColorMultiplier(Color(1.0, 0.0, 0.0, 1.0))
		render3d.SetMaterial(mat1)
		render3d.UploadGBufferConstants(cmd)
		poly1:Draw(cmd)
		-- Draw second with blue material
		local mat2 = Material.New():SetColorMultiplier(Color(0.0, 0.0, 1.0, 1.0))
		render3d.SetMaterial(mat2)
		render3d.UploadGBufferConstants(cmd)
		poly2:Draw(cmd)
	end)
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
