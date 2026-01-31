
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
local transform = require("ecs.components.3d.transform")
local light = require("ecs.components.3d.light")
local ecs = require("ecs.ecs")
require("ecs.components.3d.transform")
local Matrix44 = require("structs.matrix44")
local fs = require("fs")

T.Test3D("Polygon3D", function(draw)
	-- ============================================================================
	-- Polygon3D Creation Tests
	-- ============================================================================
	T.Test3D("Graphics Polygon3D creation", function()
		local poly = Polygon3D.New()
		T(poly)["~="](nil)
		T(poly.Vertices)["~="](nil)
		T(#poly.Vertices)["=="](0)
	end)

	T.Test3D("Graphics Polygon3D AddVertex", function()
		local poly = Polygon3D.New()
		poly:AddVertex({pos = Vec3(0, 0, 0), uv = Vec2(0, 0)})
		poly:AddVertex({pos = Vec3(1, 0, 0), uv = Vec2(1, 0)})
		poly:AddVertex({pos = Vec3(0, 1, 0), uv = Vec2(0, 1)})
		T(#poly.Vertices)["=="](3)
	end)

	-- ============================================================================
	-- Polygon3D Triangle Tests
	-- ============================================================================
	T.Test3D("Graphics Polygon3D simple triangle", function()
		local poly = Polygon3D.New()
		-- Create a simple triangle
		poly:AddVertex({pos = Vec3(-1, -1, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)})
		poly:AddVertex({pos = Vec3(1, -1, 0), uv = Vec2(1, 0), normal = Vec3(0, 0, 1)})
		poly:AddVertex({pos = Vec3(0, 1, 0), uv = Vec2(0.5, 1), normal = Vec3(0, 0, 1)})
		poly:Upload()
		T(poly.mesh)["~="](nil)
		T(poly.mesh.vertex_buffer)["~="](nil)
	end)

	-- ============================================================================
	-- Polygon3D Cube Tests
	-- ============================================================================
	T.Test3D("Graphics Polygon3D CreateCube", function()
		local poly = Polygon3D.New()
		poly:CreateCube(1.0, 1.0)
		-- Cube has 6 faces * 6 vertices (2 triangles) = 36 vertices
		T(#poly.Vertices)["=="](36)
	end)

	T.Test3D("Graphics Polygon3D CreateCube with different size", function()
		local poly = Polygon3D.New()
		poly:CreateCube(2.0, 1.0)
		T(#poly.Vertices)["=="](36)
		-- Check first vertex has correct scaled position
		T(math.abs(poly.Vertices[1].pos.x))["~"](2.0)
	end)

	-- ============================================================================
	-- Polygon3D Upload Tests
	-- ============================================================================
	T.Test3D("Graphics Polygon3D Upload with indices", function()
		local poly = Polygon3D.New()
		poly:AddVertex({pos = Vec3(0, 0, 0)})
		poly:AddVertex({pos = Vec3(1, 0, 0)})
		poly:AddVertex({pos = Vec3(0, 1, 0)})
		poly:Upload({0, 1, 2})
		T(poly.indices)["~="](nil)
		T(#poly.indices)["=="](3)
	end)

	-- ============================================================================
	-- Polygon3D Normal Tests
	-- ============================================================================
	T.Test3D("Graphics Polygon3D BuildNormals", function()
		local poly = Polygon3D.New()
		-- Create triangle without normals
		-- XY plane triangle, facing +Z
		poly:AddVertex({pos = Vec3(0, 0, 0), uv = Vec2(0, 0)})
		poly:AddVertex({pos = Vec3(1, 0, 0), uv = Vec2(1, 0)})
		poly:AddVertex({pos = Vec3(0, 1, 0), uv = Vec2(0, 1)})
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

	T.Test3D("Graphics Polygon3D BuildTangents", function()
		local poly = Polygon3D.New()
		-- Create triangle without tangents
		-- Pos: (0,0,0), (1,0,0), (0,1,0)
		-- UV:  (0,0),   (1,0),   (0,1)
		poly:AddVertex({pos = Vec3(0, 0, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)})
		poly:AddVertex({pos = Vec3(1, 0, 0), uv = Vec2(1, 0), normal = Vec3(0, 0, 1)})
		poly:AddVertex({pos = Vec3(0, 1, 0), uv = Vec2(0, 1), normal = Vec3(0, 0, 1)})
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

	T.Test3D("Graphics Polygon3D BuildNormals and Tangents YZ plane", function()
		local poly = Polygon3D.New()
		-- YZ plane triangle, facing +X
		-- Pos: (0,0,0), (0,1,0), (0,0,1)
		-- UVs: (0,0), (1,0), (0,1)
		poly:AddVertex({pos = Vec3(0, 0, 0), uv = Vec2(0, 0)})
		poly:AddVertex({pos = Vec3(0, 1, 0), uv = Vec2(1, 0)})
		poly:AddVertex({pos = Vec3(0, 0, 1), uv = Vec2(0, 1)})
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

	T.Test3D("Graphics Polygon3D BuildTangents zero UV area", function()
		local poly = Polygon3D.New()
		-- Degenerate UVs
		poly:AddVertex({pos = Vec3(0, 0, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)})
		poly:AddVertex({pos = Vec3(1, 0, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)})
		poly:AddVertex({pos = Vec3(0, 1, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)})
		poly:BuildTangents()

		-- Should not crash and should produce some tangent
		for i = 1, 3 do
			T(poly.Vertices[i].tangent)["~="](nil)
		end
	end)

	T.Test3D("Graphics Polygon3D LoadHeightmap", function()
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
		local found_height = false

		for _, v in ipairs(poly.Vertices) do
			if math.abs(v.pos.y - 5) < 0.001 then found_height = true end
		end

		T(found_height)["=="](true)
	end)

	T.Test3D("Graphics Polygon3D LoadHeightmap with pow", function()
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
	T.Test3D("Graphics Polygon3D Upload creates mesh", function()
		local poly = Polygon3D.New()
		poly:AddVertex({pos = Vec3(0, 0, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)})
		poly:AddVertex({pos = Vec3(1, 0, 0), uv = Vec2(1, 0), normal = Vec3(0, 0, 1)})
		poly:AddVertex({pos = Vec3(0, 1, 0), uv = Vec2(0, 1), normal = Vec3(0, 0, 1)})
		poly:Upload()
		T(poly.mesh)["~="](nil)
		T(poly.mesh.vertex_buffer)["~="](nil)
	end)

	T.Test3D("Graphics Polygon3D Upload with no vertices", function()
		local poly = Polygon3D.New()
		poly:Upload()
		-- Should not create mesh with no vertices
		T(poly.mesh)["=="](nil)
	end)

	-- ============================================================================
	-- Polygon3D Rendering Tests
	-- ============================================================================
	local function setup_view()
		local cam = render3d.GetCamera()
		cam:SetPosition(Vec3(0, 0, -10))
		cam:SetFOV(math.rad(45))
		return ecs.CreateFromTable(
			{
				Name = "sun",
				[transform] = {
					Rotation = Quat(0, 0, 0, -1):Normalize(),
				},
				[light] = {
					LightType = "sun",
					Color = Color(1, 1, 1),
					Intensity = 1,
				},
			}
		)
	end

	T.Test3D("Graphics Polygon3D render simple triangle", function(draw)
		local poly = Polygon3D.New()
		-- Create a triangle facing camera
		poly:AddVertex({pos = Vec3(-0.5, -0.5, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)})
		poly:AddVertex({pos = Vec3(0.5, -0.5, 0), uv = Vec2(1, 0), normal = Vec3(0, 0, 1)})
		poly:AddVertex({pos = Vec3(0, 0.5, 0), uv = Vec2(0.5, 1), normal = Vec3(0, 0, 1)})
		poly:BuildNormals()
		poly:Upload()
		local sun = setup_view()
		local draw_listener = event.AddListener("Draw3DGeometry", "test_draw", function(cmd)
			-- Set material with a base color
			local mat = Material.New():SetColorMultiplier(Color(1.0, 0.0, 0.0, 1.0))
			render3d.SetMaterial(mat)
			render3d.UploadGBufferConstants(cmd)
			poly:Draw(cmd)
		end)
		draw()
		event.RemoveListener("Draw3DGeometry", "test_draw")
		-- Test passes if no errors during draw
		T(true)["=="](true)
		sun:Remove()
	end)

	T.Test3D("Graphics Polygon3D render cube", function(draw)
		local poly = Polygon3D.New()
		poly:CreateCube(0.5, 1.0)
		poly:BuildNormals()
		poly:Upload()
		local sun = setup_view()
		render3d.GetCamera():SetPosition(Vec3(2, 2 + 1, 2))
		render3d.GetCamera():SetRotation(Quat():SetAngles(Deg3(-45, 45, 0)))
		local draw_listener = event.AddListener("Draw3DGeometry", "test_draw", function(cmd)
			-- Set material with green color
			local mat = Material.New():SetColorMultiplier(Color(0.0, 1.0, 0.0, 1.0))
			render3d.SetMaterial(mat)
			render3d.UploadGBufferConstants(cmd)
			poly:Draw(cmd)
		end)
		draw()
		event.RemoveListener("Draw3DGeometry", "test_draw")
		sun:Remove()
	end)

	T.Test3D("Graphics Polygon3D render with world matrix", function(draw)
		local poly = Polygon3D.New()
		-- Small triangle
		poly:AddVertex({pos = Vec3(-0.3, -0.3, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)})
		poly:AddVertex({pos = Vec3(0.3, -0.3, 0), uv = Vec2(1, 0), normal = Vec3(0, 0, 1)})
		poly:AddVertex({pos = Vec3(0, 0.3, 0), uv = Vec2(0.5, 1), normal = Vec3(0, 0, 1)})
		poly:BuildNormals()
		poly:Upload()
		local sun = setup_view()
		render3d.GetCamera():SetPosition(Vec3(2, 2 + 1, 2))
		render3d.GetCamera():SetRotation(Quat():SetAngles(Deg3(-45, 45, 0)))
		local draw_listener = event.AddListener("Draw3DGeometry", "test_draw", function(cmd)
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
		draw()
		event.RemoveListener("Draw3DGeometry", "test_draw")
		sun:Remove()
	end)

	T.Test3D("Graphics Polygon3D render multiple objects", function(draw)
		-- First triangle
		local poly1 = Polygon3D.New()
		poly1:AddVertex({pos = Vec3(-0.8, -0.5, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)})
		poly1:AddVertex({pos = Vec3(-0.4, -0.5, 0), uv = Vec2(1, 0), normal = Vec3(0, 0, 1)})
		poly1:AddVertex({pos = Vec3(-0.6, -0.1, 0), uv = Vec2(0.5, 1), normal = Vec3(0, 0, 1)})
		poly1:BuildNormals()
		poly1:Upload()
		-- Second triangle
		local poly2 = Polygon3D.New()
		poly2:AddVertex({pos = Vec3(0.4, 0.1, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)})
		poly2:AddVertex({pos = Vec3(0.8, 0.1, 0), uv = Vec2(1, 0), normal = Vec3(0, 0, 1)})
		poly2:AddVertex({pos = Vec3(0.6, 0.5, 0), uv = Vec2(0.5, 1), normal = Vec3(0, 0, 1)})
		poly2:BuildNormals()
		poly2:Upload()
		local sun = setup_view()
		render3d.GetCamera():SetPosition(Vec3(2, 2 + 1, 2))
		render3d.GetCamera():SetRotation(Quat():SetAngles(Deg3(-45, 45, 0)))
		local draw_listener = event.AddListener("Draw3DGeometry", "test_draw", function(cmd)
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
		draw()
		event.RemoveListener("Draw3DGeometry", "test_draw")
		sun:Remove()
	end)

	-- ============================================================================
	-- Polygon3D Clear Tests
	-- ============================================================================
	T.Test3D("Graphics Polygon3D Clear", function()
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
	T.Test3D("Graphics Polygon3D BuildBoundingBox", function()
		local poly = Polygon3D.New()
		poly:AddVertex({pos = Vec3(-1, -1, -1)})
		poly:AddVertex({pos = Vec3(1, 1, 1)})
		poly:AddVertex({pos = Vec3(0, 0, 0)})
		poly:BuildBoundingBox()
		-- AABB should have been expanded
		T(poly.AABB)["~="](nil)
	end)
end)
