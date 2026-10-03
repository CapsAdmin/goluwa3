local ffi = require("ffi")
local orientation = import("goluwa/render3d/orientation.lua")
local matrix_template = import("goluwa/structs/matrix.lua").matrix_template
local META = matrix_template(4, 4, {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1})
import.loaded["goluwa/structs/matrix44.lua"] = META.CType
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")

function META.GetInverse(m, o)
	o = o or META.CType()
	local o00 = m.m11 * m.m22 * m.m33 - m.m11 * m.m32 * m.m23 - m.m12 * m.m21 * m.m33 + m.m12 * m.m31 * m.m23 + m.m13 * m.m21 * m.m32 - m.m13 * m.m31 * m.m22
	local o01 = -m.m01 * m.m22 * m.m33 + m.m01 * m.m32 * m.m23 + m.m02 * m.m21 * m.m33 - m.m02 * m.m31 * m.m23 - m.m03 * m.m21 * m.m32 + m.m03 * m.m31 * m.m22
	local o02 = m.m01 * m.m12 * m.m33 - m.m01 * m.m32 * m.m13 - m.m02 * m.m11 * m.m33 + m.m02 * m.m31 * m.m13 + m.m03 * m.m11 * m.m32 - m.m03 * m.m31 * m.m12
	local o03 = -m.m01 * m.m12 * m.m23 + m.m01 * m.m22 * m.m13 + m.m02 * m.m11 * m.m23 - m.m02 * m.m21 * m.m13 - m.m03 * m.m11 * m.m22 + m.m03 * m.m21 * m.m12
	local o10 = -m.m10 * m.m22 * m.m33 + m.m10 * m.m32 * m.m23 + m.m12 * m.m20 * m.m33 - m.m12 * m.m30 * m.m23 - m.m13 * m.m20 * m.m32 + m.m13 * m.m30 * m.m22
	local o11 = m.m00 * m.m22 * m.m33 - m.m00 * m.m32 * m.m23 - m.m02 * m.m20 * m.m33 + m.m02 * m.m30 * m.m23 + m.m03 * m.m20 * m.m32 - m.m03 * m.m30 * m.m22
	local o12 = -m.m00 * m.m12 * m.m33 + m.m00 * m.m32 * m.m13 + m.m02 * m.m10 * m.m33 - m.m02 * m.m30 * m.m13 - m.m03 * m.m10 * m.m32 + m.m03 * m.m30 * m.m12
	local o13 = m.m00 * m.m12 * m.m23 - m.m00 * m.m22 * m.m13 - m.m02 * m.m10 * m.m23 + m.m02 * m.m20 * m.m13 + m.m03 * m.m10 * m.m22 - m.m03 * m.m20 * m.m12
	local o20 = m.m10 * m.m21 * m.m33 - m.m10 * m.m31 * m.m23 - m.m11 * m.m20 * m.m33 + m.m11 * m.m30 * m.m23 + m.m13 * m.m20 * m.m31 - m.m13 * m.m30 * m.m21
	local o21 = -m.m00 * m.m21 * m.m33 + m.m00 * m.m31 * m.m23 + m.m01 * m.m20 * m.m33 - m.m01 * m.m30 * m.m23 - m.m03 * m.m20 * m.m31 + m.m03 * m.m30 * m.m21
	local o22 = m.m00 * m.m11 * m.m33 - m.m00 * m.m31 * m.m13 - m.m01 * m.m10 * m.m33 + m.m01 * m.m30 * m.m13 + m.m03 * m.m10 * m.m31 - m.m03 * m.m30 * m.m11
	local o23 = -m.m00 * m.m11 * m.m23 + m.m00 * m.m21 * m.m13 + m.m01 * m.m10 * m.m23 - m.m01 * m.m20 * m.m13 - m.m03 * m.m10 * m.m21 + m.m03 * m.m20 * m.m11
	local o30 = -m.m10 * m.m21 * m.m32 + m.m10 * m.m31 * m.m22 + m.m11 * m.m20 * m.m32 - m.m11 * m.m30 * m.m22 - m.m12 * m.m20 * m.m31 + m.m12 * m.m30 * m.m21
	local o31 = m.m00 * m.m21 * m.m32 - m.m00 * m.m31 * m.m22 - m.m01 * m.m20 * m.m32 + m.m01 * m.m30 * m.m22 + m.m02 * m.m20 * m.m31 - m.m02 * m.m30 * m.m21
	local o32 = -m.m00 * m.m11 * m.m32 + m.m00 * m.m31 * m.m12 + m.m01 * m.m10 * m.m32 - m.m01 * m.m30 * m.m12 - m.m02 * m.m10 * m.m31 + m.m02 * m.m30 * m.m11
	local o33 = m.m00 * m.m11 * m.m22 - m.m00 * m.m21 * m.m12 - m.m01 * m.m10 * m.m22 + m.m01 * m.m20 * m.m12 + m.m02 * m.m10 * m.m21 - m.m02 * m.m20 * m.m11
	local det = 1 / (m.m00 * o00 + m.m01 * o10 + m.m02 * o20 + m.m03 * o30)
	o.m00 = o00 * det
	o.m01 = o01 * det
	o.m02 = o02 * det
	o.m03 = o03 * det
	o.m10 = o10 * det
	o.m11 = o11 * det
	o.m12 = o12 * det
	o.m13 = o13 * det
	o.m20 = o20 * det
	o.m21 = o21 * det
	o.m22 = o22 * det
	o.m23 = o23 * det
	o.m30 = o30 * det
	o.m31 = o31 * det
	o.m32 = o32 * det
	o.m33 = o33 * det
	return o
end

-- o may be a, but not b: rows of a are read before they are overwritten
function META.GetMultiplied(a, b, o)
	o = o or META.CType()
	local a0, a1, a2, a3 = a.m00, a.m01, a.m02, a.m03
	o.m00 = a0 * b.m00 + a1 * b.m10 + a2 * b.m20 + a3 * b.m30
	o.m01 = a0 * b.m01 + a1 * b.m11 + a2 * b.m21 + a3 * b.m31
	o.m02 = a0 * b.m02 + a1 * b.m12 + a2 * b.m22 + a3 * b.m32
	o.m03 = a0 * b.m03 + a1 * b.m13 + a2 * b.m23 + a3 * b.m33
	a0, a1, a2, a3 = a.m10, a.m11, a.m12, a.m13
	o.m10 = a0 * b.m00 + a1 * b.m10 + a2 * b.m20 + a3 * b.m30
	o.m11 = a0 * b.m01 + a1 * b.m11 + a2 * b.m21 + a3 * b.m31
	o.m12 = a0 * b.m02 + a1 * b.m12 + a2 * b.m22 + a3 * b.m32
	o.m13 = a0 * b.m03 + a1 * b.m13 + a2 * b.m23 + a3 * b.m33
	a0, a1, a2, a3 = a.m20, a.m21, a.m22, a.m23
	o.m20 = a0 * b.m00 + a1 * b.m10 + a2 * b.m20 + a3 * b.m30
	o.m21 = a0 * b.m01 + a1 * b.m11 + a2 * b.m21 + a3 * b.m31
	o.m22 = a0 * b.m02 + a1 * b.m12 + a2 * b.m22 + a3 * b.m32
	o.m23 = a0 * b.m03 + a1 * b.m13 + a2 * b.m23 + a3 * b.m33
	a0, a1, a2, a3 = a.m30, a.m31, a.m32, a.m33
	o.m30 = a0 * b.m00 + a1 * b.m10 + a2 * b.m20 + a3 * b.m30
	o.m31 = a0 * b.m01 + a1 * b.m11 + a2 * b.m21 + a3 * b.m31
	o.m32 = a0 * b.m02 + a1 * b.m12 + a2 * b.m22 + a3 * b.m32
	o.m33 = a0 * b.m03 + a1 * b.m13 + a2 * b.m23 + a3 * b.m33
	return o
end

function META.GetTransposed(m, o)
	o = o or META.CType()
	o.m00 = m.m00
	o.m01 = m.m10
	o.m02 = m.m20
	o.m03 = m.m30
	o.m10 = m.m01
	o.m11 = m.m11
	o.m12 = m.m21
	o.m13 = m.m31
	o.m20 = m.m02
	o.m21 = m.m12
	o.m22 = m.m22
	o.m23 = m.m32
	o.m30 = m.m03
	o.m31 = m.m13
	o.m32 = m.m23
	o.m33 = m.m33
	return o
end

function META:MultiplyVector(x, y, z, w, out)
	out = out or META.CType(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
	out.m00 = self.m00 * x + self.m10 * y + self.m20 * z + self.m30 * w
	out.m01 = self.m01 * x + self.m11 * y + self.m21 * z + self.m31 * w
	out.m02 = self.m02 * x + self.m12 * y + self.m22 * z + self.m32 * w
	out.m03 = self.m03 * x + self.m13 * y + self.m23 * z + self.m33 * w
	return out
end

function META:Skew(x, y)
	y = y or x
	x = math.rad(x)
	y = math.rad(y)
	local skew = META.CType(1, math.tan(x), 0, 0, math.tan(y), 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
	self:Multiply(skew)
	return self
end

function META:GetTranslation()
	return self.m30, self.m31, self.m32
end

function META:GetClipCoordinates()
	return self.m30 / self.m33, self.m31 / self.m33, self.m32 / self.m33
end

function META:Translate(x, y, z)
	if x == 0 and y == 0 and z == 0 then return self end

	self.m30 = self.m00 * x + self.m10 * y + self.m20 * z + self.m30
	self.m31 = self.m01 * x + self.m11 * y + self.m21 * z + self.m31
	self.m32 = self.m02 * x + self.m12 * y + self.m22 * z + self.m32
	self.m33 = self.m03 * x + self.m13 * y + self.m23 * z + self.m33
	return self
end

function META:Shear(x, y, z)
	if x == 0 and y == 0 and (not z or z == 0) then return self end

	local m00, m01, m02, m03 = self.m00, self.m01, self.m02, self.m03
	local m10, m11, m12, m13 = self.m10, self.m11, self.m12, self.m13
	self.m00 = m00 + y * m10
	self.m01 = m01 + y * m11
	self.m02 = m02 + y * m12
	self.m03 = m03 + y * m13
	self.m10 = m10 + x * m00
	self.m11 = m11 + x * m01
	self.m12 = m12 + x * m02
	self.m13 = m13 + x * m03

	if z and z ~= 0 then
		local m20, m21, m22, m23 = self.m20, self.m21, self.m22, self.m23
		self.m20 = m20 + z * m00
		self.m21 = m21 + z * m01
		self.m22 = m22 + z * m02
		self.m23 = m23 + z * m03
	end

	return self
end

function META:SetShear(x, y, z)
	self.m01 = x
	self.m10 = y
	self.m12 = z or self.m12
	return self
end

function META:SetTranslation(x, y, z)
	self.m30 = x
	self.m31 = y
	self.m32 = z
	return self
end

do
	local sin = math.sin
	local cos = math.cos
	local sqrt = math.sqrt

	function META:Rotate(a, x, y, z)
		if a == 0 then return self end

		local mag = sqrt(x * x + y * y + z * z)

		if mag <= 1.0e-4 then return self end

		x = x / mag
		y = y / mag
		z = z / mag
		-- Rodrigues' rotation formula, applied to self in place as R * self
		local s = sin(a)
		local c = cos(a)

		-- rotation about z only touches the first two rows
		if x == 0 and y == 0 then
			s = z * s
			local c0, c1 = self.m00, self.m10
			self.m00, self.m10 = c * c0 + s * c1, c * c1 - s * c0
			c0, c1 = self.m01, self.m11
			self.m01, self.m11 = c * c0 + s * c1, c * c1 - s * c0
			c0, c1 = self.m02, self.m12
			self.m02, self.m12 = c * c0 + s * c1, c * c1 - s * c0
			c0, c1 = self.m03, self.m13
			self.m03, self.m13 = c * c0 + s * c1, c * c1 - s * c0
			return self
		end

		local t = 1 - c
		local r00, r10, r20 = t * x * x + c, t * x * y - z * s, t * z * x + y * s
		local r01, r11, r21 = t * x * y + z * s, t * y * y + c, t * y * z - x * s
		local r02, r12, r22 = t * z * x - y * s, t * y * z + x * s, t * z * z + c
		local c0, c1, c2 = self.m00, self.m10, self.m20
		self.m00 = r00 * c0 + r01 * c1 + r02 * c2
		self.m10 = r10 * c0 + r11 * c1 + r12 * c2
		self.m20 = r20 * c0 + r21 * c1 + r22 * c2
		c0, c1, c2 = self.m01, self.m11, self.m21
		self.m01 = r00 * c0 + r01 * c1 + r02 * c2
		self.m11 = r10 * c0 + r11 * c1 + r12 * c2
		self.m21 = r20 * c0 + r21 * c1 + r22 * c2
		c0, c1, c2 = self.m02, self.m12, self.m22
		self.m02 = r00 * c0 + r01 * c1 + r02 * c2
		self.m12 = r10 * c0 + r11 * c1 + r12 * c2
		self.m22 = r20 * c0 + r21 * c1 + r22 * c2
		c0, c1, c2 = self.m03, self.m13, self.m23
		self.m03 = r00 * c0 + r01 * c1 + r02 * c2
		self.m13 = r10 * c0 + r11 * c1 + r12 * c2
		self.m23 = r20 * c0 + r21 * c1 + r22 * c2
		return self
	end

	-- ORIENTATION / TRANSFORMATION: Helper rotation methods using orientation module
	function META:RotatePitch(angle)
		local x, y, z = orientation.RIGHT_VECTOR:Unpack()
		return self:Rotate(angle, x, y, z)
	end

	function META:RotateYaw(angle)
		local x, y, z = orientation.UP_VECTOR:Unpack()
		return self:Rotate(angle, x, y, z)
	end

	function META:RotateRoll(angle)
		local x, y, z = orientation.FORWARD_VECTOR:Unpack()
		return self:Rotate(angle, x, y, z)
	end
end

function META:Scale(x, y, z)
	if x == 1 and y == 1 and z == 1 then return self end

	self.m00 = self.m00 * x
	self.m10 = self.m10 * y
	self.m20 = self.m20 * z
	self.m01 = self.m01 * x
	self.m11 = self.m11 * y
	self.m21 = self.m21 * z
	self.m02 = self.m02 * x
	self.m12 = self.m12 * y
	self.m22 = self.m22 * z
	self.m03 = self.m03 * x
	self.m13 = self.m13 * y
	self.m23 = self.m23 * z
	return self
end

do -- projection
	local tan = math.tan

	function META:Perspective(fov, near, far, aspect)
		local yScale = 1.0 / tan(fov / 2)
		local xScale = yScale / aspect
		local nearmfar = far - near
		-- Row-major layout (will be transposed before sending to GPU)
		-- ORIENTATION / TRANSFORMATION: Y-flip controlled by orientation module
		self.m00 = xScale
		self.m01 = 0
		self.m02 = 0
		self.m03 = 0
		self.m10 = 0
		self.m11 = orientation.PROJECTION_Y_FLIP * yScale
		self.m12 = 0
		self.m13 = 0
		self.m20 = 0
		self.m21 = 0
		self.m22 = -far / nearmfar -- Negative for Vulkan depth mapping
		self.m23 = -1
		self.m30 = 0
		self.m31 = 0
		self.m32 = -(far * near) / nearmfar -- Negative for Vulkan depth mapping
		self.m33 = 0
		return self
	end

	function META:Frustum(l, r, b, t, n, f)
		local temp = 2.0 * n
		local temp2 = r - l
		local temp3 = t - b
		local temp4 = f - n
		self.m00 = temp / temp2
		self.m01 = 0.0
		self.m02 = 0.0
		self.m03 = 0.0
		self.m10 = 0.0
		self.m11 = temp / temp3
		self.m12 = 0.0
		self.m13 = 0.0
		self.m20 = (r + l) / temp2
		self.m21 = (t + b) / temp3
		self.m22 = (-f - n) / temp4
		self.m23 = -1.0
		self.m30 = 0.0
		self.m31 = 0.0
		self.m32 = (-temp * f) / temp4
		self.m33 = 0.0
		return self
	end

	-- flip_y: optional, if true applies orientation.PROJECTION_Y_FLIP (for 3D/shadows)
	--         defaults to false for 2D compatibility
	function META:Ortho(left, right, bottom, top, near, far, flip_y)
		self.m00 = 2 / (right - left)
		--self.m10 = 0
		--self.m20 = 0
		self.m30 = -(right + left) / (right - left)
		--	self.m01 = 0
		-- ORIENTATION / TRANSFORMATION: Y-flip controlled by flip_y parameter
		local y_flip = flip_y and orientation.PROJECTION_Y_FLIP or 1
		self.m11 = y_flip * 2 / (top - bottom)
		--	self.m21 = 0
		self.m31 = -(top + bottom) / (top - bottom)
		--	self.m02 = 0
		--	self.m12 = 0
		-- Vulkan depth range [0,1] instead of OpenGL [-1,1]
		self.m22 = -1 / (far - near)
		self.m32 = -near / (far - near)
		--	self.m03 = 0
		--	self.m13 = 0
		--	self.m23 = 0
		--	self.m33 = 1
		return self
	end
end

function META:TransformVectorUnpacked(x, y, z)
	local div = x * self.m03 + y * self.m13 + z * self.m23 + self.m33
	return (x * self.m00 + y * self.m10 + z * self.m20 + self.m30) / div,
	(x * self.m01 + y * self.m11 + z * self.m21 + self.m31) / div,
	(x * self.m02 + y * self.m12 + z * self.m22 + self.m32) / div
end

function META:TransformVector(vec)
	return Vec3(self:TransformVectorUnpacked(vec.x, vec.y, vec.z))
end

function META:TransformDirection(vec)
	local origin = self:TransformVector(0, 0, 0)
	local tip = self:TransformVector(vec)
	return (tip - origin):GetNormalized()
end

function META:GetRotation(out)
	local m00, m11, m22 = self.m00, self.m11, self.m22
	local trace = m00 + m11 + m22
	local x, y, z, w

	-- branch on the largest diagonal term so rotations near 180 degrees don't divide by ~0
	if trace > 0 then
		local s = math.sqrt(1 + trace) * 2
		w = s / 4
		x = (self.m12 - self.m21) / s
		y = (self.m20 - self.m02) / s
		z = (self.m01 - self.m10) / s
	elseif m00 > m11 and m00 > m22 then
		local s = math.sqrt(1 + m00 - m11 - m22) * 2
		w = (self.m12 - self.m21) / s
		x = s / 4
		y = (self.m01 + self.m10) / s
		z = (self.m02 + self.m20) / s
	elseif m11 > m22 then
		local s = math.sqrt(1 + m11 - m00 - m22) * 2
		w = (self.m20 - self.m02) / s
		x = (self.m01 + self.m10) / s
		y = s / 4
		z = (self.m12 + self.m21) / s
	else
		local s = math.sqrt(1 + m22 - m00 - m11) * 2
		w = (self.m01 - self.m10) / s
		x = (self.m02 + self.m20) / s
		y = (self.m12 + self.m21) / s
		z = s / 4
	end

	out = out or Quat()
	out:Set(x, y, z, w)
	return out
end

function META:SetRotation(q)
	local sqw = q.w * q.w
	local sqx = q.x * q.x
	local sqy = q.y * q.y
	local sqz = q.z * q.z
	-- invs (inverse square length) is only required if quaternion is not already normalised
	local invs = 1 / (sqx + sqy + sqz + sqw)
	self.m00 = (sqx - sqy - sqz + sqw) * invs -- since sqw + sqx + sqy + sqz =1/invs*invs
	self.m11 = (-sqx + sqy - sqz + sqw) * invs
	self.m22 = (-sqx - sqy + sqz + sqw) * invs
	local tmp1, tmp2
	tmp1 = q.x * q.y
	tmp2 = q.z * q.w
	self.m10 = 2.0 * (tmp1 - tmp2) * invs
	self.m01 = 2.0 * (tmp1 + tmp2) * invs
	tmp1 = q.x * q.z
	tmp2 = q.y * q.w
	self.m20 = 2.0 * (tmp1 + tmp2) * invs
	self.m02 = 2.0 * (tmp1 - tmp2) * invs
	tmp1 = q.y * q.z
	tmp2 = q.x * q.w
	self.m21 = 2.0 * (tmp1 - tmp2) * invs
	self.m12 = 2.0 * (tmp1 + tmp2) * invs
	return self
end

function META:SetRotationFromMatrix(m)
	-- Copy rotation part (upper-left 3x3) from another matrix
	self.m00 = m.m00
	self.m01 = m.m01
	self.m02 = m.m02
	self.m10 = m.m10
	self.m11 = m.m11
	self.m12 = m.m12
	self.m20 = m.m20
	self.m21 = m.m21
	self.m22 = m.m22
	return self
end

function META:RotateQuat(q)
	self:Multiply(META.CType():SetRotation(q))
end

function META:SetAngles(ang)
	self:SetRotation(Quat():SetAngles(ang))
	return self
end

function META:GetAngles()
	return self:GetRotation():GetAngles()
end

ffi.metatype(META.CType, META)
return META.CType
