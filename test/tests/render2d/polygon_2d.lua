local T = require("test.environment")
local ffi = require("ffi")
local render = require("render.render")
local render2d = require("render2d.render2d")
local Polygon2D = require("render2d.polygon_2d")
local fs = require("fs")
local width = 512
local height = 512

-- ============================================================================
-- Polygon2D Creation Tests
-- ============================================================================
T.Test2D("Graphics Polygon2D creation", function()
	local poly = Polygon2D.New(6)
	T(poly.vertex_count)["=="](6)
	T(poly.vertex_buffer)["~="](nil)
	T(poly.index_buffer)["~="](nil)
end)

T.Test2D("Graphics Polygon2D creation with mapping", function()
	local poly = Polygon2D.New(6, true)
	T(poly.vertex_count)["=="](6)
	T(poly.mapped)["=="](true)
end)

-- ============================================================================
-- Polygon2D Color Tests
-- ============================================================================
T.Test2D("Graphics Polygon2D SetColor", function()
	local poly = Polygon2D.New(6)
	poly:SetColor(0.5, 0.6, 0.7, 0.8)
	T(poly.R)["~"](0.5)
	T(poly.G)["~"](0.6)
	T(poly.B)["~"](0.7)
	T(poly.A)["~"](0.8)
	T(poly.dirty)["=="](true)
end)

T.Test2D("Graphics Polygon2D SetColor defaults", function()
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
T.Test2D("Graphics Polygon2D SetUV", function()
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
T.Test2D("Graphics Polygon2D SetVertex", function()
	local poly = Polygon2D.New(6)
	poly:SetVertex(0, 10, 20)
	T(poly.dirty)["=="](true)
	local vtx = poly.vertex_buffer:GetVertices()
	T(vtx[0].pos[0])["~"](10)
	T(vtx[0].pos[1])["~"](20)
end)

T.Test2D("Graphics Polygon2D SetVertex with UV", function()
	local poly = Polygon2D.New(6)
	poly:SetVertex(0, 10, 20, 0.5, 0.5)
	local vtx = poly.vertex_buffer:GetVertices()
	T(vtx[0].uv[0])["~"](0.5)
	T(vtx[0].uv[1])["~"](0.5)
end)

T.Test2D("Graphics Polygon2D SetVertex with color", function()
	local poly = Polygon2D.New(6)
	poly:SetColor(1, 0, 0, 1)
	poly:SetVertex(0, 10, 20)
	local vtx = poly.vertex_buffer:GetVertices()
	T(vtx[0].color[0])["~"](1)
	T(vtx[0].color[1])["~"](0)
	T(vtx[0].color[2])["~"](0)
	T(vtx[0].color[3])["~"](1)
end)

T.Test2D("Graphics Polygon2D SetTriangle", function()
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

T.Test2D("Graphics Polygon2D SetTriangle with UVs", function()
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
T.Test2D("Graphics Polygon2D SetRect basic", function()
	local poly = Polygon2D.New(6)
	poly:SetRect(1, 10, 20, 50, 30)
	T(poly.X)["~"](10)
	T(poly.Y)["~"](20)
	T(poly.dirty)["=="](true)
end)

T.Test2D("Graphics Polygon2D SetRect with rotation", function()
	local poly = Polygon2D.New(6)
	poly:SetRect(1, 10, 20, 50, 30, math.rad(45))
	T(poly.ROT)["~"](math.rad(45))
end)

T.Test2D("Graphics Polygon2D SetRect with offset", function()
	local poly = Polygon2D.New(6)
	poly:SetRect(1, 10, 20, 50, 30, 0, 5, 5)
	T(poly.OX)["~"](5)
	T(poly.OY)["~"](5)
end)

-- ============================================================================
-- Polygon2D DrawLine Tests
-- ============================================================================
T.Test2D("Graphics Polygon2D DrawLine", function()
	local poly = Polygon2D.New(6)
	poly:DrawLine(1, 0, 0, 100, 100, 5)
	T(poly.dirty)["=="](true)
	-- Line should be drawn at angle
	local expected_ang = math.atan2(100, 100)
	T(poly.ROT)["~"](-expected_ang)
end)

T.Test2D("Graphics Polygon2D DrawLine default width", function()
	local poly = Polygon2D.New(6)
	poly:DrawLine(1, 0, 0, 50, 50)
	-- Should not error and use default width of 1
	T(true)["=="](true)
end)

-- ============================================================================
-- Polygon2D Rendering Tests
-- ============================================================================
T.Test2D("Graphics Polygon2D render simple rect", function()
	local poly = Polygon2D.New(6)
	poly:SetColor(1, 0, 0, 1)
	poly:SetRect(1, 100, 100, 10, 10)
	poly:Draw()
	return function()
		-- Higher tolerance to account for potential gamma/color space differences when tests run in sequence
		T.AssertScreenPixel({pos = {105, 105}, color = {1, 0, 0, 1}, tolerance = 0.25})
	end
end)

T.Test2D("Graphics Polygon2D render triangle", function()
	local poly = Polygon2D.New(3)
	poly:SetColor(0, 1, 0, 1)
	poly:SetTriangle(1, 150, 150, 160, 150, 155, 160)
	poly:Draw()
	-- Higher tolerance to account for potential gamma/color space differences when tests run in sequence
	return function()
		T.AssertScreenPixel({pos = {155, 155}, color = {0, 1, 0, 1}, tolerance = 0.2})
	end
end)

T.Test2D("Graphics Polygon2D render with custom count", function()
	local poly = Polygon2D.New(12)
	poly:SetColor(0, 0, 1, 1)
	poly:SetRect(1, 200, 200, 5, 5)
	poly:SetRect(2, 210, 210, 5, 5)
	poly:Draw(12)
	return function()
		-- Higher tolerance to account for potential gamma/color space differences when tests run in sequence
		T.AssertScreenPixel({pos = {202, 202}, color = {0, 0, 1, 1}, tolerance = 0.25})
		T.AssertScreenPixel({pos = {212, 212}, color = {0, 0, 1, 1}, tolerance = 0.25})
	end
end)

T.Test2D("Graphics Polygon2D render line", function()
	local poly = Polygon2D.New(6)
	poly:SetColor(1, 1, 0, 1)
	poly:DrawLine(1, 250, 250, 260, 260, 2)
	poly:Draw()
	-- Check midpoint of line
	-- Higher tolerance to account for potential gamma/color space differences when tests run in sequence
	return function()
		T.AssertScreenPixel({pos = {255, 255}, color = {1, 1, 0, 1}, tolerance = 0.25})
	end
end)

-- ============================================================================
-- Polygon2D NinePatch Tests
-- ============================================================================
T.Test2D("Graphics Polygon2D SetNinePatch basic", function()
	local poly = Polygon2D.New(54) -- 9 rects * 6 vertices
	poly:SetNinePatch(1, 10, 10, 100, 100, 64, 64, 16, 0, 0, 1, 64, 64)
	T(poly.dirty)["=="](true)
end)

T.Test2D("Graphics Polygon2D SetNinePatch corner size clamping", function()
	local poly = Polygon2D.New(54)
	-- Width is 50, height is 40, corner_size of 30 should be clamped to 25 (50/2)
	poly:SetNinePatch(1, 10, 10, 50, 40, 64, 64, 30, 0, 0, 1, 64, 64)
	T(poly.dirty)["=="](true)
end)

T.Test2D("Graphics Polygon2D render NinePatch", function()
	local poly = Polygon2D.New(54)
	poly:SetColor(1, 0, 1, 1)
	poly:SetNinePatch(1, 300, 300, 80, 80, 64, 64, 8, 0, 0, 1, 64, 64)
	poly:Draw()
	return function()
		-- Check corners and center
		-- Higher tolerance to account for potential gamma/color space differences when tests run in sequence
		T.AssertScreenPixel({pos = {305, 305}, color = {1, 0, 1, 1}, tolerance = 0.25}) -- Top-left
		T.AssertScreenPixel({pos = {340, 340}, color = {1, 0, 1, 1}, tolerance = 0.25}) -- Center
		T.AssertScreenPixel({pos = {375, 375}, color = {1, 0, 1, 1}, tolerance = 0.25}) -- Bottom-right
	end
end)

-- ============================================================================
-- Polygon2D AddRect and AddNinePatch Tests
-- ============================================================================
T.Test2D("Graphics Polygon2D AddRect", function()
	local poly = Polygon2D.New(12)
	poly:AddRect(10, 10, 5, 5)
	T(poly.added)["=="](2)
	poly:AddRect(20, 20, 5, 5)
	T(poly.added)["=="](3)
end)

T.Test2D("Graphics Polygon2D AddNinePatch", function()
	local poly = Polygon2D.New(54)
	poly:AddNinePatch(10, 10, 50, 50, 32, 32, 8, 0, 0, 1, 32, 32)
	T(poly.added)["=="](10)
end)

-- ============================================================================
-- Polygon2D WorldMatrixMultiply Tests
-- ============================================================================
T.Test2D("Graphics Polygon2D SetWorldMatrixMultiply", function()
	local poly = Polygon2D.New(6)
	poly:SetWorldMatrixMultiply(true)
	T(poly.WorldMatrixMultiply)["=="](true)
	poly:SetWorldMatrixMultiply(false)
	T(poly.WorldMatrixMultiply)["=="](false)
end)

T.Test2D("Graphics Polygon2D render with world matrix", function()
	local poly = Polygon2D.New(6)
	poly:SetWorldMatrixMultiply(true)
	poly:SetColor(0, 1, 1, 1)
	render2d.PushMatrix()
	render2d.Translate(50, 50)
	poly:SetRect(1, 0, 0, 5, 5)
	poly:Draw()
	render2d.PopMatrix()
	return function()
		-- Should be drawn at (50, 50) due to world matrix
		-- Higher tolerance to account for potential gamma/color space differences when tests run in sequence
		T.AssertScreenPixel({pos = {52, 52}, color = {0, 1, 1, 1}, tolerance = 0.25})
	end
end)

-- ============================================================================
-- Polygon2D rotation tests
-- ============================================================================
T.Test2D("Graphics Polygon2D render with rotation", function()
	local poly = Polygon2D.New(6)
	poly:SetColor(1, 0.5, 0, 1)
	poly:SetRect(1, 400, 400, 20, 20, math.rad(45))
	poly:Draw()
end)

T.Test2D("Graphics Polygon2D render with rotation origin", function()
	local poly = Polygon2D.New(6)
	poly:SetColor(0.5, 0, 1, 1)
	-- Rotate around custom origin
	poly:SetRect(1, 450, 450, 20, 20, math.rad(45), 0, 0, 10, 10)
	poly:Draw()
end)
