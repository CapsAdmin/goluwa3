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
	local Light = require("components.light")
	local sun = Light.CreateDirectional({color = {1, 1, 1}, intensity = 1})
	sun:SetIsSun(true)
	sun:SetRotation(Quat(0, 0, 0, 1))
	render3d.SetLights({sun})
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
		local mat = Material.New():SetColorMultiplier(Color(1.0, 0.0, 0.0, 1.0))
		render3d.SetMaterial(mat)
		render3d.UploadConstants(cmd)
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
		render3d.UploadConstants(cmd)
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
		render3d.UploadConstants(cmd)
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
		render3d.UploadConstants(cmd)
		poly1:Draw(cmd)
		-- Draw second with blue material
		local mat2 = Material.New():SetColorMultiplier(Color(0.0, 0.0, 1.0, 1.0))
		render3d.SetMaterial(mat2)
		render3d.UploadConstants(cmd)
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
