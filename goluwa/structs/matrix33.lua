local ffi = require("ffi")
local orientation = import("goluwa/render3d/orientation.lua")
local matrix_template = import("goluwa/structs/matrix.lua").matrix_template
local META = matrix_template(3, 3, {1, 0, 0, 0, 1, 0, 0, 0, 1})
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")

function META:SetZero()
	self.m00 = 0
	self.m01 = 0
	self.m02 = 0
	self.m10 = 0
	self.m11 = 0
	self.m12 = 0
	self.m20 = 0
	self.m21 = 0
	self.m22 = 0
	return self
end

function META:SetDiagonal(x, y, z)
	self:SetZero()
	self.m00 = x or 0
	self.m11 = y or 0
	self.m22 = z or 0
	return self
end

function META:GetDeterminant()
	return self.m00 * (
			self.m11 * self.m22 - self.m12 * self.m21
		) - self.m01 * (
			self.m10 * self.m22 - self.m12 * self.m20
		) + self.m02 * (
			self.m10 * self.m21 - self.m11 * self.m20
		)
end

function META.GetInverse(m, o)
	o = o or META.CType()
	local det = m:GetDeterminant()

	if math.abs(det) <= 1e-12 then return o:SetZero() end

	local inv_det = 1 / det
	o.m00 = (m.m11 * m.m22 - m.m12 * m.m21) * inv_det
	o.m01 = (m.m02 * m.m21 - m.m01 * m.m22) * inv_det
	o.m02 = (m.m01 * m.m12 - m.m02 * m.m11) * inv_det
	o.m10 = (m.m12 * m.m20 - m.m10 * m.m22) * inv_det
	o.m11 = (m.m00 * m.m22 - m.m02 * m.m20) * inv_det
	o.m12 = (m.m02 * m.m10 - m.m00 * m.m12) * inv_det
	o.m20 = (m.m10 * m.m21 - m.m11 * m.m20) * inv_det
	o.m21 = (m.m01 * m.m20 - m.m00 * m.m21) * inv_det
	o.m22 = (m.m00 * m.m11 - m.m01 * m.m10) * inv_det
	return o
end

function META.GetAdded(a, b, o)
	o = o or META.CType()
	o.m00 = a.m00 + b.m00
	o.m01 = a.m01 + b.m01
	o.m02 = a.m02 + b.m02
	o.m10 = a.m10 + b.m10
	o.m11 = a.m11 + b.m11
	o.m12 = a.m12 + b.m12
	o.m20 = a.m20 + b.m20
	o.m21 = a.m21 + b.m21
	o.m22 = a.m22 + b.m22
	return o
end

function META:Add(other, out)
	return META.GetAdded(self, other, out or self)
end

function META.GetScaled(m, scalar, o)
	o = o or META.CType()
	o.m00 = m.m00 * scalar
	o.m01 = m.m01 * scalar
	o.m02 = m.m02 * scalar
	o.m10 = m.m10 * scalar
	o.m11 = m.m11 * scalar
	o.m12 = m.m12 * scalar
	o.m20 = m.m20 * scalar
	o.m21 = m.m21 * scalar
	o.m22 = m.m22 * scalar
	return o
end

function META:ScaleScalar(scalar, out)
	return META.GetScaled(self, scalar, out or self)
end

function META:TransformVectorUnpacked(x, y, z)
	return self.m00 * x + self.m01 * y + self.m02 * z,
	self.m10 * x + self.m11 * y + self.m12 * z,
	self.m20 * x + self.m21 * y + self.m22 * z
end

function META:TransformVector(vec)
	return Vec3(self:TransformVectorUnpacked(vec.x, vec.y, vec.z))
end

function META:TransformDirection(vec)
	local origin = self:TransformVector(0, 0, 0)
	local tip = self:TransformVector(vec)
	return (tip - origin):GetNormalized()
end

function META:TransformVector(vec)
	return Vec3(self:TransformVectorUnpacked(vec.x, vec.y, vec.z))
end

function META:VecMul(vec, out)
	local x, y, z = self:TransformVectorUnpacked(vec.x, vec.y, vec.z)
	out = out or Vec3()
	out.x = x
	out.y = y
	out.z = z
	return out
end

function META:SetRotation(q)
	local sqw = q.w * q.w
	local sqx = q.x * q.x
	local sqy = q.y * q.y
	local sqz = q.z * q.z
	local invs = 1 / (sqx + sqy + sqz + sqw)
	self.m00 = (sqx - sqy - sqz + sqw) * invs
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

function META:GetRotation(out)
	local w = math.sqrt(math.max(0, 1 + self.m00 + self.m11 + self.m22)) / 2
	local w2 = w * 4

	if math.abs(w2) <= 1e-12 then
		out = out or Quat()
		out:Set(0, 0, 0, 1)
		return out
	end

	local x = (self.m21 - self.m12) / w2
	local y = (self.m02 - self.m20) / w2
	local z = (self.m10 - self.m01) / w2
	out = out or Quat()
	out:Set(x, y, z, w)
	return out
end

ffi.metatype(META.CType, META)
return META.CType
