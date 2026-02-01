local T = require("test.environment")
local math2d = require("render2d.math2d")

-- ============================================================================
-- math2d.GetPolygonArea Tests
-- ============================================================================
T.Test("math2d.GetPolygonArea square", function()
	local square = {0, 0, 10, 0, 10, 10, 0, 10}
	local area = math2d.GetPolygonArea(square)
	T(math.abs(area))["=="](100)
end)

T.Test("math2d.GetPolygonArea triangle", function()
	local tri = {0, 0, 10, 0, 0, 10}
	local area = math2d.GetPolygonArea(tri)
	T(math.abs(area))["=="](50)
end)

T.Test("math2d.GetPolygonArea orientation", function()
	local ccw = {0, 0, 10, 0, 10, 10, 0, 10}
	local cw = {0, 0, 0, 10, 10, 10, 10, 0}
	
	T(math2d.GetPolygonArea(ccw))["=="](100)
	T(math2d.GetPolygonArea(cw))["=="](-100)
	
	T(math2d.IsPolygonCCW(ccw))["=="](true)
	T(math2d.IsPolygonCCW(cw))["=="](false)
end)

T.Test("math2d.GetPolygonArea empty/small", function()
	T(math2d.GetPolygonArea({}))["=="](0)
	T(math2d.GetPolygonArea({0, 0, 10, 10}))["=="](0)
end)

-- ============================================================================
-- math2d.TriangulateCoordinates Tests
-- ============================================================================
T.Test("math2d.TriangulateCoordinates square", function()
	local square = {0, 0, 10, 0, 10, 10, 0, 10}
	local tris = math2d.TriangulateCoordinates(square)
	
	-- Square should yield 2 triangles = 12 coordinates
	T(#tris)["=="](12)
	
	-- Verify total area of triangles matches polygon area
	local total_area = 0
	for i = 1, #tris, 6 do
		local tri_area = math2d.GetPolygonArea({tris[i], tris[i+1], tris[i+2], tris[i+3], tris[i+4], tris[i+5]})
		total_area = total_area + math.abs(tri_area)
	end
	T(total_area)["=="](100)
end)

T.Test("math2d.TriangulateCoordinates concave (L-shape)", function()
	-- L-shape polygon
	-- (0,10)---(10,10)
	--   |         |
	-- (0,0)---(5,0)---(5,5)---(10,5) -- wait that's not right
	
	local l_shape = {
		0, 0,
		10, 0,
		10, 5,
		5, 5,
		5, 10,
		0, 10
	}
	-- Area should be (10*5) + (5*5) = 75
	T(math.abs(math2d.GetPolygonArea(l_shape)))["=="](75)
	
	local tris = math2d.TriangulateCoordinates(l_shape)
	
	-- 6 vertices -> 4 triangles -> 24 coordinates
	T(#tris)["=="](24)
	
	local total_area = 0
	for i = 1, #tris, 6 do
		local tri_area = math2d.GetPolygonArea({tris[i], tris[i+1], tris[i+2], tris[i+3], tris[i+4], tris[i+5]})
		total_area = total_area + math.abs(tri_area)
	end
	T(total_area)["~"](75)
end)

T.Test("math2d.TriangulateCoordinates self-closing / redundant points", function()
	-- Points with a redundant last point (same as first) and a duplicate middle point
	local points = {0, 0, 10, 0, 10, 0, 10, 10, 0, 10, 0, 0}
	local tris = math2d.TriangulateCoordinates(points)
	
	-- Should still yield 2 triangles for the square
	T(#tris)["=="](12)
end)

T.Test("math2d.TriangulateCoordinates degenerate", function()
	T(#math2d.TriangulateCoordinates({0, 0, 10, 10, 20, 20}))["=="](0)
	T(#math2d.TriangulateCoordinates({0, 0}))["=="](0)
end)
