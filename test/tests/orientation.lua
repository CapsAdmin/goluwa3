require("test.environment")
local orientation = require("orientation")
local Vec3 = require("structs.vec3")
local Ang3 = require("structs.ang3")
local Quat = require("structs.quat")
local Matrix44 = require("structs.matrix").Matrix44

test("orientation vectors are normalized", function()
	local function vec_length(v)
		return Vec3(unpack(v)):GetLength()
	end

	attest.almost_equal(vec_length(orientation.UP_VECTOR), 1)
	attest.almost_equal(vec_length(orientation.RIGHT_VECTOR), 1)
	attest.almost_equal(vec_length(orientation.FORWARD_VECTOR), 1)
end)

test("orientation vectors are orthogonal (Y-up, X-right, Z-forward)", function()
	attest.equal(orientation.RIGHT_VECTOR[1], 1)
	attest.equal(orientation.UP_VECTOR[2], 1)
	attest.equal(orientation.FORWARD_VECTOR[3], 1)
end)

test("Ang3 GetForward at zero rotation", function()
	local a = Ang3(0, 0, 0)
	local fwd = a:GetForward()
	local len = math.sqrt(fwd.x * fwd.x + fwd.y * fwd.y + fwd.z * fwd.z)
	attest.almost_equal(len, 1)
end)

test("Ang3 GetUp/Right/Forward at zero rotation", function()
	attest.equal(Ang3(0, 0, 0):GetUp(), Vec3(unpack(orientation.UP_VECTOR)))
	attest.equal(Ang3(0, 0, 0):GetRight(), Vec3(unpack(orientation.RIGHT_VECTOR)))
	attest.equal(Ang3(0, 0, 0):GetForward(), Vec3(unpack(orientation.FORWARD_VECTOR)))
end)

test("Quat directional methods use orientation module", function()
	attest.equal(Quat():GetUp(), Vec3(unpack(orientation.UP_VECTOR)))
	attest.equal(Quat():GetRight(), Vec3(unpack(orientation.RIGHT_VECTOR)))
	attest.equal(Quat():GetForward(), Vec3(unpack(orientation.FORWARD_VECTOR)))
end)

test("Ang3 GetDirection transforms vectors", function()
	attest.equal(
		Ang3(0, 0, 0):GetDirection(orientation.GetRightVector()),
		Vec3(unpack(orientation.RIGHT_VECTOR))
	)
end)

test("Ang3 GetDirection with 90 degree yaw", function()
	attest.almost_equal(Ang3(0, math.pi / 2, 0):GetDirection(1, 0, 0):GetLength(), 1)
end)

test("Ang3 GetForward with yaw rotation", function()
	attest.almost_equal(Ang3(0, math.pi / 2, 0):GetForward():GetLength(), 1)
end)

test("Matrix44 rotation helpers use orientation module", function()
	local m = Matrix44()
	local result = m:RotatePitch(0.1)
	attest.equal(("%p"):format(result), ("%p"):format(m))
	m:Identity()
	result = m:RotateYaw(0.1)
	attest.equal(("%p"):format(result), ("%p"):format(m))
	m:Identity()
	result = m:RotateRoll(0.1)
	attest.equal(("%p"):format(result), ("%p"):format(m))
end)

test("Matrix44 Perspective uses orientation Y-flip", function()
	local m = Matrix44()
	m:Perspective(math.pi / 4, 0.1, 1000, 16 / 9)

	if orientation.PROJECTION_Y_FLIP == -1 then
		attest.ok(m.m11 < 0)
	else
		attest.ok(m.m11 > 0)
	end
end)

test("Ang3 GetDirection matches Quat VecMul", function()
	local ang = Ang3(0.2, 0.7, -0.3)
	local quat = Quat():SetAngles(ang)
	local test_vec = Vec3(1, 2, 3):GetNormalized()
	local ang_result = ang:GetDirection(test_vec)
	local quat_result = quat:VecMul(test_vec)
	attest.almost_equal(ang_result.x, quat_result.x)
	attest.almost_equal(ang_result.y, quat_result.y)
	attest.almost_equal(ang_result.z, quat_result.z)
end)
