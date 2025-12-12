local test = require("test.gambarina")
require("goluwa.global_environment")
local Quat = require("structs.quat")
local Vec3 = require("structs.vec3")
local Ang3 = require("structs.ang3")

test("Quat construction", function()
	local q = Quat(1, 2, 3, 4)
	ok(q.x == 1, "x should be 1")
	ok(q.y == 2, "y should be 2")
	ok(q.z == 3, "z should be 3")
	ok(q.w == 4, "w should be 4")
end)

test("Quat default construction", function()
	local q = Quat()
	ok(q.x == 0, "x should default to 0")
	ok(q.y == 0, "y should default to 0")
	ok(q.z == 0, "z should default to 0")
	ok(q.w == 0, "w should default to 0")
end)

test("Quat identity", function()
	local q = Quat(1, 2, 3, 4)
	q:Identity()
	ok(q.x == 0, "identity x should be 0")
	ok(q.y == 0, "identity y should be 0")
	ok(q.z == 0, "identity z should be 0")
	ok(q.w == 1, "identity w should be 1")
end)

test("Quat copy", function()
	local q1 = Quat(1, 2, 3, 4)
	local q2 = q1:Copy()
	ok(q2.x == 1, "copied x should be 1")
	ok(q2.y == 2, "copied y should be 2")
	ok(q2.z == 3, "copied z should be 3")
	ok(q2.w == 4, "copied w should be 4")
	q2.x = 10
	ok(q1.x == 1, "original x should still be 1")
end)

test("Quat scalar multiplication", function()
	local q = Quat(1, 2, 3, 4)
	local q2 = q * 2
	ok(q2.x == 2, "x should be 2")
	ok(q2.y == 4, "y should be 4")
	ok(q2.z == 6, "z should be 6")
	ok(q2.w == 8, "w should be 8")
end)

test("Quat scalar division", function()
	local q = Quat(2, 4, 6, 8)
	local q2 = q / 2
	ok(q2.x == 1, "x should be 1")
	ok(q2.y == 2, "y should be 2")
	ok(q2.z == 3, "z should be 3")
	ok(q2.w == 4, "w should be 4")
end)

test("Quat conjugate", function()
	local q = Quat(1, 2, 3, 4)
	local conj = q:GetConjugated()
	ok(conj.x == -1, "conjugate x should be -1")
	ok(conj.y == -2, "conjugate y should be -2")
	ok(conj.z == -3, "conjugate z should be -3")
	ok(conj.w == 4, "conjugate w should remain 4")
end)

test("Quat dot product", function()
	local q1 = Quat(1, 0, 0, 0)
	local q2 = Quat(1, 0, 0, 0)
	local dot = q1:Dot(q2)
	ok(dot == 1, "dot product of same quat should be 1")
end)

test("Quat dot product orthogonal", function()
	local q1 = Quat(1, 0, 0, 0)
	local q2 = Quat(0, 1, 0, 0)
	local dot = q1:Dot(q2)
	ok(dot == 0, "dot product of orthogonal quats should be 0")
end)

test("Quat length", function()
	local q = Quat(0, 0, 0, 1)
	local len = q:GetLength()
	ok(math.abs(len - 1) < 0.0001, "identity quat length should be 1")
end)

test("Quat length non-unit", function()
	local q = Quat(1, 2, 2, 0)
	local len = q:GetLength()
	ok(math.abs(len - 3) < 0.0001, "length should be 3")
end)

test("Quat normalize", function()
	local q = Quat(0, 0, 0, 2)
	q:Normalize()
	ok(math.abs(q:GetLength() - 1) < 0.0001, "normalized quat should have length 1")
	ok(math.abs(q.w - 1) < 0.0001, "normalized w should be 1")
end)

test("Quat normalize general", function()
	local q = Quat(1, 2, 2, 0)
	local n = q:GetNormalized()
	ok(math.abs(n:GetLength() - 1) < 0.0001, "normalized quat should have length 1")
end)

test("Quat lerp", function()
	local q1 = Quat(0, 0, 0, 1)
	local q2 = Quat(0, 0, 0, 0)
	local lerped = q1:GetLerped(0.5, q2)
	ok(math.abs(lerped.w - 0.5) < 0.0001, "lerped w should be 0.5")
end)

test("Quat SetAngles and GetAngles roundtrip", function()
	-- Use zero angles for a clean roundtrip test
	local ang = Ang3(0, 0, 0)
	local q = Quat():SetAngles(ang)
	local ang2 = q:GetAngles()
	ok(math.abs(ang2.x) < 0.0001, "zero angle pitch should stay ~0 after roundtrip")
	ok(math.abs(ang2.y) < 0.0001, "zero angle yaw should stay ~0 after roundtrip")
	ok(math.abs(ang2.z) < 0.0001, "zero angle roll should stay ~0 after roundtrip")
end)

test("Quat SetAngles produces valid quaternion", function()
	local ang = Ang3(0.5, 0.3, 0.1)
	local q = Quat():SetAngles(ang)
	-- A rotation quaternion should be normalized
	ok(math.abs(q:GetLength() - 1) < 0.0001, "quat from angles should be unit length")
	-- GetAngles should return an Ang3
	local ang2 = q:GetAngles()
	ok(ang2 ~= nil, "GetAngles should return a value")
end)

test("Quat identity angles", function()
	local q = Quat()
	q:Identity()
	local ang = q:GetAngles()
	ok(math.abs(ang.x) < 0.0001, "identity pitch should be ~0")
	ok(math.abs(ang.y) < 0.0001, "identity yaw should be ~0")
	ok(math.abs(ang.z) < 0.0001, "identity roll should be ~0")
end)

test("QuatFromAxis", function()
	local axis = Vec3(0, 0, 1)
	local q = QuatFromAxis(math.pi / 2, axis) -- 90 degrees around Z
	ok(q ~= nil, "QuatFromAxis should return a quat")
	ok(math.abs(q:GetLength() - 1) < 0.0001, "axis-angle quat should be unit length")
end)

test("Quat multiplication identity", function()
	local q1 = Quat()
	q1:Identity()
	local q2 = Quat()
	q2:Identity()
	local q3 = q1 * q2
	ok(math.abs(q3.w - 1) < 0.0001, "identity * identity w should be ~1")
	ok(math.abs(q3.x) < 0.0001, "identity * identity x should be ~0")
	ok(math.abs(q3.y) < 0.0001, "identity * identity y should be ~0")
	ok(math.abs(q3.z) < 0.0001, "identity * identity z should be ~0")
end)

test("Quat equality", function()
	local q1 = Quat(1, 2, 3, 4)
	local q2 = Quat(1, 2, 3, 4)
	local q3 = Quat(1, 2, 3, 5)
	ok(q1 == q2, "equal quats should be equal")
	ok(not (q1 == q3), "different quats should not be equal")
end)

test("Quat GetFloatPointer", function()
	local q = Quat(1, 2, 3, 4)
	local ptr = q:GetFloatPointer()
	ok(ptr ~= nil, "GetFloatPointer should return a pointer")
	ok(ptr[0] == 1, "float pointer x should be 1")
	ok(ptr[1] == 2, "float pointer y should be 2")
	ok(ptr[2] == 3, "float pointer z should be 3")
	ok(ptr[3] == 4, "float pointer w should be 4")
end)

test("Quat GetDoublePointer", function()
	local q = Quat(1, 2, 3, 4)
	local ptr = q:GetDoublePointer()
	ok(ptr ~= nil, "GetDoublePointer should return a pointer")
	ok(ptr[0] == 1, "double pointer x should be 1")
	ok(ptr[1] == 2, "double pointer y should be 2")
	ok(ptr[2] == 3, "double pointer z should be 3")
	ok(ptr[3] == 4, "double pointer w should be 4")
end)

test("Quat Rotate around X axis", function()
	local q = Quat()
	q:Identity()
	local angle = math.pi / 2 -- 90 degrees
	q:Rotate(angle, 1, 0, 0) -- Rotate around X axis
	ok(q.x ~= 0, "x component should be non-zero after X rotation")
	ok(math.abs(q:GetLength() - 1) < 0.0001, "quat should remain unit length after rotation")
end)

test("Quat Rotate around Y axis", function()
	local q = Quat()
	q:Identity()
	local angle = math.pi / 2 -- 90 degrees
	q:Rotate(angle, 0, 1, 0) -- Rotate around Y axis
	ok(q.y ~= 0, "y component should be non-zero after Y rotation")
	ok(math.abs(q:GetLength() - 1) < 0.0001, "quat should remain unit length after rotation")
end)

test("Quat Rotate around Z axis", function()
	local q = Quat()
	q:Identity()
	local angle = math.pi / 2 -- 90 degrees
	q:Rotate(angle, 0, 0, 1) -- Rotate around Z axis
	ok(q.z ~= 0, "z component should be non-zero after Z rotation")
	ok(math.abs(q:GetLength() - 1) < 0.0001, "quat should remain unit length after rotation")
end)

test("Quat Rotate modifies quaternion in place", function()
	local q = Quat()
	q:Identity()
	local original_w = q.w
	q:Rotate(0.1, 1, 0, 0) -- Small rotation around X
	ok(q.w ~= original_w, "w should change after rotation")
	ok(q.x ~= 0, "x should be non-zero after X rotation")
end)

test("Quat RotatePitch", function()
	local q = Quat()
	q:Identity()
	local angle = math.pi / 4 -- 45 degrees
	q:RotatePitch(angle)
	ok(math.abs(q:GetLength() - 1) < 0.0001, "quat should remain unit length")
	-- Pitch should modify the quaternion
	ok(
		not (q.x == 0 and q.y == 0 and q.z == 0 and q.w == 1),
		"quat should change from identity"
	)
end)

test("Quat RotateYaw", function()
	local q = Quat()
	q:Identity()
	local angle = math.pi / 4 -- 45 degrees
	q:RotateYaw(angle)
	ok(math.abs(q:GetLength() - 1) < 0.0001, "quat should remain unit length")
	ok(
		not (q.x == 0 and q.y == 0 and q.z == 0 and q.w == 1),
		"quat should change from identity"
	)
end)

test("Quat RotateRoll", function()
	local q = Quat()
	q:Identity()
	local angle = math.pi / 4 -- 45 degrees
	q:RotateRoll(angle)
	ok(math.abs(q:GetLength() - 1) < 0.0001, "quat should remain unit length")
	ok(
		not (q.x == 0 and q.y == 0 and q.z == 0 and q.w == 1),
		"quat should change from identity"
	)
end)

test("Quat multiple rotations", function()
	local q = Quat()
	q:Identity()
	q:RotatePitch(0.1)
	q:RotateYaw(0.2)
	q:RotateRoll(0.3)
	ok(
		math.abs(q:GetLength() - 1) < 0.0001,
		"quat should remain unit length after multiple rotations"
	)
end)

test("Quat Rotate with zero angle", function()
	local q = Quat()
	q:Identity()
	q:Rotate(0, 1, 0, 0)
	ok(
		q.x == 0 and q.y == 0 and q.z == 0 and q.w == 1,
		"zero rotation should not change identity quat"
	)
end)
