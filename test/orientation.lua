local test = require("test.gambarina")
require("goluwa.global_environment")
local orientation = require("orientation")
local Vec3 = require("structs.vec3")
local Ang3 = require("structs.ang3")
local Quat = require("structs.quat")
local Matrix44 = require("structs.matrix").Matrix44

-- Test the coordinate system configuration
test("orientation module defines vectors", function()
	ok(orientation.UP_VECTOR ~= nil, "UP_VECTOR should be defined")
	ok(orientation.DOWN_VECTOR ~= nil, "DOWN_VECTOR should be defined")
	ok(orientation.RIGHT_VECTOR ~= nil, "RIGHT_VECTOR should be defined")
	ok(orientation.LEFT_VECTOR ~= nil, "LEFT_VECTOR should be defined")
	ok(orientation.FORWARD_VECTOR ~= nil, "FORWARD_VECTOR should be defined")
	ok(orientation.BACKWARD_VECTOR ~= nil, "BACKWARD_VECTOR should be defined")
end)

test("orientation vectors are normalized", function()
	local function vec_length(v)
		return math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
	end

	ok(
		math.abs(vec_length(orientation.UP_VECTOR) - 1) < 0.0001,
		"UP_VECTOR should be unit length"
	)
	ok(
		math.abs(vec_length(orientation.RIGHT_VECTOR) - 1) < 0.0001,
		"RIGHT_VECTOR should be unit length"
	)
	ok(
		math.abs(vec_length(orientation.FORWARD_VECTOR) - 1) < 0.0001,
		"FORWARD_VECTOR should be unit length"
	)
end)

test("orientation vectors are orthogonal (Y-up, X-right, Z-forward)", function()
	-- For Y-up, X-right, Z-forward:
	-- UP should be {0, 1, 0}
	-- RIGHT should be {1, 0, 0}
	-- FORWARD should be {0, 0, 1}
	ok(
		orientation.UP_VECTOR[1] == 0 and
			orientation.UP_VECTOR[2] == 1 and
			orientation.UP_VECTOR[3] == 0,
		"UP should be Y-axis"
	)
	ok(
		orientation.RIGHT_VECTOR[1] == 1 and
			orientation.RIGHT_VECTOR[2] == 0 and
			orientation.RIGHT_VECTOR[3] == 0,
		"RIGHT should be X-axis"
	)
	ok(
		orientation.FORWARD_VECTOR[1] == 0 and
			orientation.FORWARD_VECTOR[2] == 0 and
			orientation.FORWARD_VECTOR[3] == 1,
		"FORWARD should be Z-axis"
	)
end)

-- Test Ang3 orientation methods
test("Ang3 GetForward at zero rotation", function()
	-- Looking straight ahead (no rotation) should give a consistent forward vector
	local a = Ang3(0, 0, 0)
	local fwd = a:GetForward()
	-- Should be normalized
	local len = math.sqrt(fwd.x * fwd.x + fwd.y * fwd.y + fwd.z * fwd.z)
	ok(math.abs(len - 1) < 0.0001, "forward should be unit length")
end)

test("Ang3 GetForward with yaw rotation", function()
	-- Yaw 90 degrees should rotate around the up axis
	local a = Ang3(0, math.pi / 2, 0)
	local fwd = a:GetForward()
	-- Should be normalized
	local len = math.sqrt(fwd.x * fwd.x + fwd.y * fwd.y + fwd.z * fwd.z)
	ok(math.abs(len - 1) < 0.0001, "forward should be unit length after rotation")
end)

test("Ang3 GetUp at zero rotation", function()
	local a = Ang3(0, 0, 0)
	local up = a:GetUp()
	-- At zero rotation, up should be close to the world up
	-- In Y-up system, this should be {0, 1, 0} or close to Z depending on convention
	ok(math.abs(up.z) > 0.9 or math.abs(up.y) > 0.9, "up should align with world up axis")
end)

test("Ang3 GetDirection transforms vectors", function()
	local a = Ang3(0, 0, 0)
	-- Transform the right vector through identity rotation
	local transformed = a:GetDirection(orientation.GetRightVector())
	ok(
		math.abs(transformed.x - orientation.RIGHT_VECTOR[1]) < 0.0001,
		"identity rotation should preserve X"
	)
	ok(
		math.abs(transformed.y - orientation.RIGHT_VECTOR[2]) < 0.0001,
		"identity rotation should preserve Y"
	)
	ok(
		math.abs(transformed.z - orientation.RIGHT_VECTOR[3]) < 0.0001,
		"identity rotation should preserve Z"
	)
end)

test("Ang3 GetDirection with 90 degree yaw", function()
	local a = Ang3(0, math.pi / 2, 0)
	-- Transform a vector by 90 degree yaw (rotation around up axis)
	local transformed = a:GetDirection(1, 0, 0) -- Start with X-axis
	-- Should be normalized
	local len = math.sqrt(
		transformed.x * transformed.x + transformed.y * transformed.y + transformed.z * transformed.z
	)
	ok(math.abs(len - 1) < 0.0001, "transformed vector should be unit length")
end)

-- Test Quat orientation methods
test("Quat directional methods use orientation module", function()
	local q = Quat()
	q:Identity()
	local up = q:GetUp()
	local right = q:GetRight()
	local forward = q:GetForward()
	-- Identity quat should return the base orientation vectors
	ok(math.abs(up.x - orientation.UP_VECTOR[1]) < 0.0001, "quat up.x matches orientation")
	ok(math.abs(up.y - orientation.UP_VECTOR[2]) < 0.0001, "quat up.y matches orientation")
	ok(math.abs(up.z - orientation.UP_VECTOR[3]) < 0.0001, "quat up.z matches orientation")
	ok(
		math.abs(right.x - orientation.RIGHT_VECTOR[1]) < 0.0001,
		"quat right.x matches orientation"
	)
	ok(
		math.abs(right.y - orientation.RIGHT_VECTOR[2]) < 0.0001,
		"quat right.y matches orientation"
	)
	ok(
		math.abs(right.z - orientation.RIGHT_VECTOR[3]) < 0.0001,
		"quat right.z matches orientation"
	)
	ok(
		math.abs(forward.x - orientation.FORWARD_VECTOR[1]) < 0.0001,
		"quat forward.x matches orientation"
	)
	ok(
		math.abs(forward.y - orientation.FORWARD_VECTOR[2]) < 0.0001,
		"quat forward.y matches orientation"
	)
	ok(
		math.abs(forward.z - orientation.FORWARD_VECTOR[3]) < 0.0001,
		"quat forward.z matches orientation"
	)
end)

-- Test Matrix44 orientation methods
test("Matrix44 rotation helpers use orientation module", function()
	local m = Matrix44()
	m:Identity()
	-- RotatePitch/Yaw/Roll should use orientation vectors
	-- Just verify they execute without error and return self
	local result = m:RotatePitch(0.1)
	ok(result == m, "RotatePitch should return self")
	m:Identity()
	result = m:RotateYaw(0.1)
	ok(result == m, "RotateYaw should return self")
	m:Identity()
	result = m:RotateRoll(0.1)
	ok(result == m, "RotateRoll should return self")
end)

test("Matrix44 Perspective uses orientation Y-flip", function()
	local m = Matrix44()
	m:Perspective(math.pi / 4, 0.1, 1000, 16 / 9)

	-- Check that m11 (Y scale) has the flip applied
	-- For Vulkan (Y-down NDC), PROJECTION_Y_FLIP = -1, so m11 should be negative
	if orientation.PROJECTION_Y_FLIP == -1 then
		ok(m.m11 < 0, "m11 should be negative with Y-flip = -1")
	else
		ok(m.m11 > 0, "m11 should be positive with Y-flip = 1")
	end
end)

-- Test consistency between Ang3, Quat, and Matrix44
-- Note: Ang3's GetForward/Up/Right use Source-engine style hardcoded formulas
-- while Quat uses orientation module vectors, so they may differ.
-- The GetDirection method should match though, as both apply Euler rotations.
test("Ang3 GetDirection matches Quat VecMul", function()
	local ang = Ang3(0.2, 0.7, -0.3)
	local quat = Quat():SetAngles(ang)
	local test_vec = Vec3(1, 2, 3):GetNormalized()
	local ang_result = ang:GetDirection(test_vec)
	local quat_result = quat:VecMul(test_vec)
	ok(
		math.abs(ang_result.x - quat_result.x) < 0.001,
		"GetDirection.x should match VecMul.x"
	)
	ok(
		math.abs(ang_result.y - quat_result.y) < 0.001,
		"GetDirection.y should match VecMul.y"
	)
	ok(
		math.abs(ang_result.z - quat_result.z) < 0.001,
		"GetDirection.z should match VecMul.z"
	)
end)
