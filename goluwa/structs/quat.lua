local Ang3 = require("structs.ang3")
local Vec3 = require("structs.vec3")
local structs = require("structs.structs")
local orientation = require("render3d.orientation")
local META = structs.Template("Quat")
local ffi = require("ffi")
local CTOR
META.Args = {{"x", "y", "z", "w"}}
structs.AddAllOperators(META)

function QuatDeg3(...)
	return CTOR():SetAngles(Deg3(...))
end

function QuatFromAxis(rad, axis)
	rad = rad * 0.5
	local s = math.sin(rad)
	return CTOR(axis.x * s, axis.y * s, axis.z * s, math.cos(rad))
end

function META:Identity()
	self.x = 0
	self.y = 0
	self.z = 0
	self.w = 1
end

function META.__mul(a, b)
	if type(b) == "number" then
		return CTOR(a.x * b, a.y * b, a.z * b, a.w * b)
	end

	local w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
	local x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y
	local y = a.w * b.y + a.y * b.w + a.z * b.x - a.x * b.z
	local z = a.w * b.z + a.z * b.w + a.x * b.y - a.y * b.x
	return CTOR(x, y, z, w)
end

function META.VecMul(a, b)
	local vec, quat

	if typex(a) == "vec3" then vec, quat = a, b else vec, quat = b, a end

	local qvec = Vec3(quat.x, quat.y, quat.z)
	local uvec = qvec:GetCross(vec)
	local uuvec = qvec:GetCross(uvec)
	uvec, uuvec = uvec * 2 * quat.w, uuvec * 2
	return vec + uvec + uuvec
end

do -- ORIENTATION / TRANSFORMATION
	-- Coordinate system defined in orientation.lua
	function META:Right()
		return self:VecMul(Vec3(orientation.GetRightVector()))
	end

	META.GetRight = META.Right

	function META:Left()
		return self:VecMul(Vec3(orientation.GetLeftVector()))
	end

	META.GetLeft = META.Left

	function META:Up()
		return self:VecMul(Vec3(orientation.GetUpVector()))
	end

	META.GetUp = META.Up

	function META:Down()
		return self:VecMul(Vec3(orientation.GetDownVector()))
	end

	META.GetDown = META.Down

	function META:Front()
		return self:VecMul(Vec3(orientation.GetForwardVector()))
	end

	META.GetFront = META.Front

	function META:Back()
		return self:VecMul(Vec3(orientation.GetBackwardVector()))
	end

	META.GetBack = META.Back
	META.Forward = META.Front
	META.GetForward = META.Front
	META.Backward = META.Back
	META.GetBackward = META.Back
end

function META.__div(a, b)
	if type(b) == "number" then
		return CTOR(a.x / b, a.y / b, a.z / b, a.w / b)
	end

	return a:GetConjugated():__div(a:Dot(a))
end

function META:Conjugate()
	self.x = -self.x
	self.y = -self.y
	self.z = -self.z
	return self
end

structs.AddGetFunc(META, "Conjugate", "Conjugated")

function META.Lerp(a, mult, b)
	a.x = (b.x - a.x) * mult + a.x
	a.y = (b.y - a.y) * mult + a.y
	a.z = (b.z - a.z) * mult + a.z
	a.w = (b.w - a.w) * mult + a.w
	return a
end

structs.AddGetFunc(META, "Lerp", "Lerped")

function META:Dot(vec)
	return self.w * vec.w + self.x * vec.x + self.y * vec.y + self.z * vec.z
end

function META:GetLength()
	return math.sqrt(self:Dot(self))
end

function META:Normalize()
	local len = self:GetLength()

	if len > 0 then
		local div = 1 / len
		self.x = self.x * div
		self.y = self.y * div
		self.z = self.z * div
		self.w = self.w * div
	else
		self:Identity()
	end

	return self
end

structs.AddGetFunc(META, "Normalize", "Normalized")

-- ORIENTATION / TRANSFORMATION: Converts Euler angles to quaternion
-- ang.x = pitch (rotation around orientation.RIGHT_VECTOR axis)
-- ang.y = yaw (rotation around orientation.UP_VECTOR axis)
-- ang.z = roll (rotation around orientation.FORWARD_VECTOR axis)
-- Builds quaternion by composing rotations in same order as Ang3:GetDirection
-- This ensures Quat():SetAngles(ang):VecMul(v) == ang:GetDirection(v)
function META:SetAngles(ang)
	-- Build quaternion by composing axis rotations in same order as Ang3.GetDirection
	-- Order: Roll (Z), then Pitch (X), then Yaw (Y)
	-- Start with identity
	self:Identity()

	-- Apply roll around BACKWARD axis
	if ang.z ~= 0 then
		local fx, fy, fz = orientation.GetBackwardVector()
		local half = ang.z * 0.5
		local s = math.sin(half)
		local roll_q = CTOR(fx * s, fy * s, fz * s, math.cos(half))
		local result = roll_q * self -- apply in world space
		self.x, self.y, self.z, self.w = result.x, result.y, result.z, result.w
	end

	-- Apply pitch around RIGHT axis
	if ang.x ~= 0 then
		local rx, ry, rz = orientation.GetRightVector()
		local half = ang.x * 0.5
		local s = math.sin(half)
		local pitch_q = CTOR(rx * s, ry * s, rz * s, math.cos(half))
		local result = pitch_q * self -- apply in world space
		self.x, self.y, self.z, self.w = result.x, result.y, result.z, result.w
	end

	-- Apply yaw around UP axis
	if ang.y ~= 0 then
		local ux, uy, uz = orientation.GetUpVector()
		local half = ang.y * 0.5
		local s = math.sin(half)
		local yaw_q = CTOR(ux * s, uy * s, uz * s, math.cos(half))
		local result = yaw_q * self -- apply in world space
		self.x, self.y, self.z, self.w = result.x, result.y, result.z, result.w
	end

	return self
end

do
	-- https://github.com/grrrwaaa/gct753/blob/master/modules/quat.lua#L465
	local function twoaxisrot(r11, r12, r21, r31, r32)
		return Ang3(math.atan2(r11, r12), math.acos(r21), math.atan2(r31, r32))
	end

	local function threeaxisrot(r11, r12, r21, r31, r32)
		return Ang3(math.atan2(r31, r32), math.asin(r21), math.atan2(r11, r12))
	end

	function META.GetAngles(q, seq)
		-- Extract Euler angles from quaternion
		-- Default extraction matches SetAngles: Yaw (Y) → Pitch (X, negated) → Roll (Z)
		-- This ensures roundtrip: Quat():SetAngles(ang):GetAngles() == ang
		if not seq then
			local x, y, z, w = q.x, q.y, q.z, q.w
			local pitch = math.asin(math.max(-1, math.min(1, 2.0 * (w * x - y * z))))
			local yaw = math.atan2(2.0 * (w * y + x * z), w * w - x * x - y * y + z * z)
			local roll = math.atan2(2.0 * (w * z + x * y), w * w - x * x + y * y - z * z)
			return Ang3(pitch, yaw, roll)
		end

		-- For other sequences, use the library functions below
		if seq == "zxy" then
			return threeaxisrot(
				2 * (q.x * q.y + q.w * q.z),
				q.w * q.w + q.x * q.x - q.y * q.y - q.z * q.z,
				-2 * (q.x * q.z - q.w * q.y),
				2 * (q.y * q.z + q.w * q.x),
				q.w * q.w - q.x * q.x - q.y * q.y + q.z * q.z
			)
		elseif seq == "zyz" then
			return twoaxisrot(
				2 * (q.y * q.z - q.w * q.x),
				2 * (q.x * q.z + q.w * q.y),
				q.w * q.w - q.x * q.x - q.y * q.y + q.z * q.z,
				2 * (q.y * q.z + q.w * q.x),
				-2 * (q.x * q.z - q.w * q.y)
			)
		elseif seq == "zxy" then
			return threeaxisrot(
				-2 * (q.x * q.y - q.w * q.z),
				q.w * q.w - q.x * q.x + q.y * q.y - q.z * q.z,
				2 * (q.y * q.z + q.w * q.x),
				-2 * (q.x * q.z - q.w * q.y),
				q.w * q.w - q.x * q.x - q.y * q.y + q.z * q.z
			)
		elseif seq == "zxz" then
			return twoaxisrot(
				2 * (q.x * q.z + q.w * q.y),
				-2 * (q.y * q.z - q.w * q.x),
				q.w * q.w - q.x * q.x - q.y * q.y + q.z * q.z,
				2 * (q.x * q.z - q.w * q.y),
				2 * (q.y * q.z + q.w * q.x)
			)
		elseif seq == "yxz" then
			return threeaxisrot(
				2 * (q.x * q.z + q.w * q.y),
				q.w * q.w - q.x * q.x - q.y * q.y + q.z * q.z,
				-2 * (q.y * q.z - q.w * q.x),
				2 * (q.x * q.y + q.w * q.z),
				q.w * q.w - q.x * q.x + q.y * q.y - q.z * q.z
			)
		elseif seq == "yxy" then
			return twoaxisrot(
				2 * (q.x * q.y - q.w * q.z),
				2 * (q.y * q.z + q.w * q.x),
				q.w * q.w - q.x * q.x + q.y * q.y - q.z * q.z,
				2 * (q.x * q.y + q.w * q.z),
				-2 * (q.y * q.z - q.w * q.x)
			)
		elseif seq == "yzx" then
			return threeaxisrot(
				-2 * (q.x * q.z - q.w * q.y),
				q.w * q.w + q.x * q.x - q.y * q.y - q.z * q.z,
				2 * (q.x * q.y + q.w * q.z),
				-2 * (q.y * q.z - q.w * q.x),
				q.w * q.w - q.x * q.x + q.y * q.y - q.z * q.z
			)
		elseif seq == "yzy" then
			return twoaxisrot(
				2 * (q.y * q.z + q.w * q.x),
				-2 * (q.x * q.y - q.w * q.z),
				q.w * q.w - q.x * q.x + q.y * q.y - q.z * q.z,
				2 * (q.y * q.z - q.w * q.x),
				2 * (q.x * q.y + q.w * q.z)
			)
		elseif seq == "xyz" then
			return threeaxisrot(
				-2 * (q.y * q.z - q.w * q.x),
				q.w * q.w - q.x * q.x - q.y * q.y + q.z * q.z,
				2 * (q.x * q.z + q.w * q.y),
				-2 * (q.x * q.y - q.w * q.z),
				q.w * q.w + q.x * q.x - q.y * q.y - q.z * q.z
			)
		elseif seq == "xyx" then
			return twoaxisrot(
				2 * (q.x * q.y + q.w * q.z),
				-2 * (q.x * q.z - q.w * q.y),
				q.w * q.w + q.x * q.x - q.y * q.y - q.z * q.z,
				2 * (q.x * q.y - q.w * q.z),
				2 * (q.x * q.z + q.w * q.y)
			)
		elseif seq == "xzy" then
			return threeaxisrot(
				2 * (q.y * q.z + q.w * q.x),
				q.w * q.w - q.x * q.x + q.y * q.y - q.z * q.z,
				-2 * (q.x * q.y - q.w * q.z),
				2 * (q.x * q.z + q.w * q.y),
				q.w * q.w + q.x * q.x - q.y * q.y - q.z * q.z
			)
		elseif seq == "xzx" then
			return twoaxisrot(
				2 * (q.x * q.z - q.w * q.y),
				2 * (q.x * q.y + q.w * q.z),
				q.w * q.w + q.x * q.x - q.y * q.y - q.z * q.z,
				2 * (q.x * q.z + q.w * q.y),
				-2 * (q.x * q.y - q.w * q.z)
			)
		end
	end
end

-- Convert quaternion to a rotation matrix
function META:GetMatrix()
	local Matrix44 = require("structs.matrix44")
	local m = Matrix44()
	local xx = self.x * self.x
	local xy = self.x * self.y
	local xz = self.x * self.z
	local xw = self.x * self.w
	local yy = self.y * self.y
	local yz = self.y * self.z
	local yw = self.y * self.w
	local zz = self.z * self.z
	local zw = self.z * self.w
	m.m00 = 1 - 2 * (yy + zz)
	m.m01 = 2 * (xy + zw)
	m.m02 = 2 * (xz - yw)
	m.m03 = 0
	m.m10 = 2 * (xy - zw)
	m.m11 = 1 - 2 * (xx + zz)
	m.m12 = 2 * (yz + xw)
	m.m13 = 0
	m.m20 = 2 * (xz + yw)
	m.m21 = 2 * (yz - xw)
	m.m22 = 1 - 2 * (xx + yy)
	m.m23 = 0
	m.m30 = 0
	m.m31 = 0
	m.m32 = 0
	m.m33 = 1
	return m
end

-- Rotate quaternion by angle around axis
function META:Rotate(angle, x, y, z)
	if angle == 0 then return self end

	-- Normalize axis vector
	local mag = math.sqrt(x * x + y * y + z * z)

	if mag <= 1.0e-4 then return self end

	x = x / mag
	y = y / mag
	z = z / mag
	-- Create rotation quaternion from axis-angle
	local half_angle = angle * 0.5
	local s = math.sin(half_angle)
	local rotation = CTOR(x * s, y * s, z * s, math.cos(half_angle))
	-- Multiply self by rotation quaternion
	local result = self * rotation
	self.x = result.x
	self.y = result.y
	self.z = result.z
	self.w = result.w
	return self
end

-- ORIENTATION / TRANSFORMATION: Helper rotation methods using orientation module
function META:RotatePitch(angle)
	local x, y, z = orientation.GetRightVector()
	return self:Rotate(angle, x, y, z)
end

function META:RotateYaw(angle)
	local x, y, z = orientation.GetUpVector()
	return self:Rotate(angle, x, y, z)
end

function META:RotateRoll(angle)
	local x, y, z = orientation.GetBackwardVector()
	return self:Rotate(angle, x, y, z)
end

CTOR = structs.Register(META)
return CTOR
