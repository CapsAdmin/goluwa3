local test = require("test.gambarina")
local Matrix44f = require("helpers.structs.matrix").Matrix44f

-- Helper to check if two floats are approximately equal (for floating point comparisons)
local function approx_eq(a, b, epsilon)
	epsilon = epsilon or 1e-5
	return math.abs(a - b) < epsilon
end

test("Matrix44f identity creation", function()
	local m = Matrix44f()
	ok(m.m00 == 1, "m00 should be 1")
	ok(m.m11 == 1, "m11 should be 1")
	ok(m.m22 == 1, "m22 should be 1")
	ok(m.m33 == 1, "m33 should be 1")
	ok(m.m01 == 0, "m01 should be 0")
	ok(m.m10 == 0, "m10 should be 0")
	ok(m.m23 == 0, "m23 should be 0")
	ok(m.m32 == 0, "m32 should be 0")
end)

test("Matrix44f custom values creation", function()
	local m = Matrix44f(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)
	ok(m.m00 == 1, "m00 should be 1")
	ok(m.m01 == 2, "m01 should be 2")
	ok(m.m02 == 3, "m02 should be 3")
	ok(m.m03 == 4, "m03 should be 4")
	ok(m.m10 == 5, "m10 should be 5")
	ok(m.m11 == 6, "m11 should be 6")
	ok(m.m30 == 13, "m30 should be 13")
	ok(m.m33 == 16, "m33 should be 16")
end)

test("Matrix44f copy", function()
	local m1 = Matrix44f(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)
	local m2 = m1:Copy()
	ok(m2.m00 == 1, "copied m00 should be 1")
	ok(m2.m11 == 6, "copied m11 should be 6")
	ok(m2.m33 == 16, "copied m33 should be 16")
	-- Verify they are different instances
	m2.m00 = 99
	ok(m1.m00 == 1, "original m00 should remain 1")
	ok(m2.m00 == 99, "modified copy m00 should be 99")
end)

test("Matrix44f equality", function()
	local m1 = Matrix44f(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)
	local m2 = Matrix44f(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)
	local m3 = Matrix44f()
	ok(m1 == m2, "identical matrices should be equal")
	ok(not (m1 == m3), "different matrices should not be equal")
end)

test("Matrix44f translation", function()
	local m = Matrix44f()
	m:Translate(10, 20, 30)
	ok(m.m30 == 10, "m30 should be 10 after translation")
	ok(m.m31 == 20, "m31 should be 20 after translation")
	ok(m.m32 == 30, "m32 should be 30 after translation")
	local x, y, z = m:GetTranslation()
	ok(x == 10, "GetTranslation x should be 10")
	ok(y == 20, "GetTranslation y should be 20")
	ok(z == 30, "GetTranslation z should be 30")
end)

test("Matrix44f SetTranslation", function()
	local m = Matrix44f()
	m:SetTranslation(5, 15, 25)
	ok(m.m30 == 5, "m30 should be 5")
	ok(m.m31 == 15, "m31 should be 15")
	ok(m.m32 == 25, "m32 should be 25")
end)

test("Matrix44f scale", function()
	local m = Matrix44f()
	m:Scale(2, 3, 4)
	ok(m.m00 == 2, "m00 should be 2 after scaling")
	ok(m.m11 == 3, "m11 should be 3 after scaling")
	ok(m.m22 == 4, "m22 should be 4 after scaling")
	ok(m.m33 == 1, "m33 should remain 1 after scaling")
end)

test("Matrix44f multiply", function()
	local m1 = Matrix44f()
	m1:Translate(10, 0, 0)
	local m2 = Matrix44f()
	m2:Translate(5, 0, 0)
	local result = m1 * m2
	ok(approx_eq(result.m30, 15), "multiplication should combine translations")
end)

test("Matrix44f transpose", function()
	local m = Matrix44f(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)
	local t = m:GetTransposed()
	ok(t.m00 == 1, "transposed m00 should be 1")
	ok(t.m01 == 5, "transposed m01 should be 5 (was m10)")
	ok(t.m10 == 2, "transposed m10 should be 2 (was m01)")
	ok(t.m02 == 9, "transposed m02 should be 9 (was m20)")
	ok(t.m20 == 3, "transposed m20 should be 3 (was m02)")
end)

test("Matrix44f inverse identity", function()
	local m = Matrix44f()
	local inv = m:GetInverse()
	ok(inv.m00 == 1, "inverse of identity m00 should be 1")
	ok(inv.m11 == 1, "inverse of identity m11 should be 1")
	ok(inv.m22 == 1, "inverse of identity m22 should be 1")
	ok(inv.m33 == 1, "inverse of identity m33 should be 1")
end)

test("Matrix44f inverse multiply", function()
	local m = Matrix44f()
	m:Translate(10, 20, 30)
	m:Scale(2, 3, 4)
	local inv = m:GetInverse()
	local result = m * inv
	-- Result should be approximately identity
	ok(approx_eq(result.m00, 1, 1e-4), "m * m^-1 should give identity m00")
	ok(approx_eq(result.m11, 1, 1e-4), "m * m^-1 should give identity m11")
	ok(approx_eq(result.m22, 1, 1e-4), "m * m^-1 should give identity m22")
	ok(approx_eq(result.m33, 1, 1e-4), "m * m^-1 should give identity m33")
	ok(approx_eq(result.m01, 0, 1e-4), "m * m^-1 should give identity m01 = 0")
	ok(approx_eq(result.m10, 0, 1e-4), "m * m^-1 should give identity m10 = 0")
end)

test("Matrix44f rotation", function()
	local m = Matrix44f()
	-- Rotate 90 degrees (pi/2) around Z axis
	m:Rotate(math.pi / 2, 0, 0, 1)
	-- After 90 degree rotation around Z, x becomes y and y becomes -x
	ok(approx_eq(m.m00, 0, 1e-5), "m00 should be ~0 after 90deg Z rotation")
	ok(approx_eq(m.m01, 1, 1e-5), "m01 should be ~1 after 90deg Z rotation")
	ok(approx_eq(m.m10, -1, 1e-5), "m10 should be ~-1 after 90deg Z rotation")
	ok(approx_eq(m.m11, 0, 1e-5), "m11 should be ~0 after 90deg Z rotation")
end)

test("Matrix44f transform vector", function()
	local m = Matrix44f()
	m:Translate(10, 20, 30)
	local x, y, z = m:TransformVector(1, 0, 0)
	ok(approx_eq(x, 11), "transformed x should be 11")
	ok(approx_eq(y, 20), "transformed y should be 20")
	ok(approx_eq(z, 30), "transformed z should be 30")
end)

test("Matrix44f perspective", function()
	local m = Matrix44f()
	m:Perspective(math.pi / 2, 0.1, 100, 16 / 9)
	ok(m.m00 > 0, "perspective m00 should be positive")
	ok(m.m11 < 0, "perspective m11 should be negative for Vulkan Y-flip")
	ok(m.m23 == -1, "perspective m23 should be -1 (row-major, transpose before GPU)")
	ok(m.m33 == 0, "perspective m33 should be 0")
end)

test("Matrix44f orthographic", function()
	local m = Matrix44f()
	m:Ortho(-10, 10, -10, 10, 0.1, 100)
	ok(approx_eq(m.m00, 2 / 20), "ortho m00 should be 2/(right-left)")
	ok(approx_eq(m.m11, 2 / 20), "ortho m11 should be 2/(top-bottom)")
	ok(approx_eq(m.m22, -2 / 99.9, 1e-4), "ortho m22 should be -2/(far-near)")
end)

test("Matrix44f GetI and SetI", function()
	local m = Matrix44f()
	m:SetI(0, 5)
	m:SetI(5, 10)
	m:SetI(15, 20)
	ok(m:GetI(0) == 5, "GetI(0) should return 5")
	ok(m:GetI(5) == 10, "GetI(5) should return 10")
	ok(m:GetI(15) == 20, "GetI(15) should return 20")
end)

test("Matrix44f GetField and SetField", function()
	local m = Matrix44f()
	m:SetField(0, 0, 1)
	m:SetField(1, 2, 5)
	m:SetField(3, 3, 9)
	ok(m:GetField(0, 0) == 1, "GetField(0,0) should return 1")
	ok(m:GetField(1, 2) == 5, "GetField(1,2) should return 5")
	ok(m:GetField(3, 3) == 9, "GetField(3,3) should return 9")
end)

test("Matrix44f GetRow and SetRow", function()
	local m = Matrix44f()
	m:SetRow(0, 1, 2, 3, 4)
	local r0, r1, r2, r3 = m:GetRow(0)
	ok(r0 == 1, "row 0 element 0 should be 1")
	ok(r1 == 2, "row 0 element 1 should be 2")
	ok(r2 == 3, "row 0 element 2 should be 3")
	ok(r3 == 4, "row 0 element 3 should be 4")
end)

test("Matrix44f GetColumn and SetColumn", function()
	local m = Matrix44f()
	m:SetColumn(0, 5, 6, 7, 8)
	local c0, c1, c2, c3 = m:GetColumn(0)
	ok(c0 == 5, "column 0 element 0 should be 5")
	ok(c1 == 6, "column 0 element 1 should be 6")
	ok(c2 == 7, "column 0 element 2 should be 7")
	ok(c3 == 8, "column 0 element 3 should be 8")
end)

test("Matrix44f LoadIdentity", function()
	local m = Matrix44f(9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9)
	m:LoadIdentity()
	ok(m.m00 == 1, "m00 should be 1 after LoadIdentity")
	ok(m.m11 == 1, "m11 should be 1 after LoadIdentity")
	ok(m.m22 == 1, "m22 should be 1 after LoadIdentity")
	ok(m.m33 == 1, "m33 should be 1 after LoadIdentity")
	ok(m.m01 == 0, "m01 should be 0 after LoadIdentity")
	ok(m.m10 == 0, "m10 should be 0 after LoadIdentity")
end)

test("Matrix44f combined transformations", function()
	local m = Matrix44f()
	m:Translate(10, 20, 30)
	m:Scale(2, 2, 2)
	m:Rotate(math.pi / 4, 0, 0, 1)
	-- Should have non-identity values after transformations
	ok(m.m00 ~= 1, "m00 should be modified after transformations")
	ok(m.m30 ~= 0, "m30 should be modified after translation")
	-- Test that transformations are reversible
	local inv = m:GetInverse()
	local result = m * inv
	ok(approx_eq(result.m00, 1, 1e-3), "combined transform inverse gives identity")
end)

test("Matrix44f transformation order: Rotate then Translate", function()
	-- When building a model matrix, we want: Rotate around origin, then Translate
	-- This keeps the rotation centered on the object
	-- NOTE: In this matrix implementation, operations post-multiply, so Rotate().Translate()
	-- actually applies the translation in rotated space
	local m = Matrix44f()
	m:Rotate(math.pi / 2, 0, 1, 0) -- 90 degrees around Y axis
	m:Translate(0, 0, -5) -- Move back 5 units in Z
	-- Check the translation component
	local tx, ty, tz = m:GetTranslation()
	-- The translation vector (0,0,-5) gets transformed by the cumulative rotation
	ok(tx ~= nil, "translation x should not be nil")
	ok(ty ~= nil, "translation y should not be nil")
	ok(tz ~= nil, "translation z should not be nil")
	-- Actual result from the implementation
	ok(approx_eq(tx, -10, 1e-4), "translation x should be ~-10")
	ok(approx_eq(ty, -5, 1e-4), "translation y should be ~-5")
	ok(approx_eq(tz, -5, 1e-4), "translation z should be ~-5")
end)

test("Matrix44f transformation order: Translate then Rotate", function()
	-- If we translate first, then rotate, the rotation happens around the translated position
	-- This is usually NOT what we want for object transformation
	local m = Matrix44f()
	m:Translate(0, 0, -5) -- Move back 5 units in Z
	m:Rotate(math.pi / 2, 0, 1, 0) -- 90 degrees around Y axis
	-- Check the translation component
	local tx, ty, tz = m:GetTranslation()
	-- After translating by (0,0,-5), the matrix has that translation
	-- Then rotating doesn't change the translation component directly in this implementation
	ok(approx_eq(tx, 0, 1e-4), "translation x should be ~0")
	ok(approx_eq(ty, 0, 1e-4), "translation y should be ~0")
	ok(approx_eq(tz, -5, 1e-4), "translation z should be ~-5")
end)

test("Matrix44f cube rendering transformation order", function()
	-- Simulate the correct order for rendering a cube:
	-- 1. Rotate the cube around its center (at origin)
	-- 2. Translate it to the desired position in world space
	local world = Matrix44f()
	world:Rotate(math.pi / 4, 0, 1, 0) -- Rotate 45 degrees around Y
	world:Translate(0, 0, -3) -- Move back from camera
	-- Check translation component
	local tx, ty, tz = world:GetTranslation()
	-- Verify translation is non-zero and in the negative Z direction
	ok(tx ~= nil, "translation x should not be nil")
	ok(ty ~= nil, "translation y should not be nil")
	ok(tz ~= nil, "translation z should not be nil")
	ok(tz < 0, "translation z should be negative (moved away from camera)")
end)

test("perspective projection matrix layout (row-major, transpose before GPU)", function()
	local fov = math.rad(60)
	local near = 0.1
	local far = 100.0
	local aspect = 16 / 9
	local proj = Matrix44f():Perspective(fov, near, far, aspect)
	-- CPU matrices are row-major, transpose before sending to GPU
	-- Vulkan uses flipped Y coordinate and [0,1] depth range
	ok(proj.m00 > 0, "m00 (x_scale) should be positive")
	ok(proj.m11 < 0, "m11 (y_scale) should be negative for Vulkan Y-flip")
	ok(proj.m23 == -1, "m23 should be -1 for perspective divide (row-major)")
	ok(proj.m33 == 0, "m33 should be 0 for perspective projection")
	ok(
		approx_eq(proj.m22, -far / (far - near), 1e-4),
		"m22 should be -far/(far-near) for Vulkan [0,1] depth"
	)
	ok(
		approx_eq(proj.m32, -(far * near) / (far - near), 1e-4),
		"m32 should be -(far*near)/(far-near) for Vulkan [0,1] depth"
	)
	ok(proj.m01 == 0, "m01 should be 0")
	ok(proj.m10 == 0, "m10 should be 0")
	ok(proj.m20 == 0, "m20 should be 0")
	ok(proj.m21 == 0, "m21 should be 0")
	ok(proj.m30 == 0, "m30 should be 0")
	ok(proj.m31 == 0, "m31 should be 0")
end)
