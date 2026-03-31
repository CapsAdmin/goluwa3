local structs = import("goluwa/structs/structs.lua")
local math3d = import("goluwa/render3d/math3d.lua")
local META = structs.Template("Vec3")
META.Args = {{"x", "y", "z"}, {"r", "g", "b"}, {"p", "y", "r"}, {"u", "v", "w"}}
structs.AddAllOperators(META)
structs.AddOperator(META, "generic_vector")
structs.Swizzle(META)
structs.Swizzle(META, 2, "structs.Vec2")

function META.FromValue(value, y, z)
	if y ~= nil or z ~= nil then return META.CType(value or 0, y or 0, z or 0) end

	if value == nil then return META.CType() end

	if type(value) == "number" then return META.CType(value, 0, 0) end

	return META.CType(value.x or value[1] or 0, value.y or value[2] or 0, value.z or value[3] or 0)
end

function META.Cross(a, b)
	local x, y, z = a.x, a.y, a.z
	a.x = y * b.z - z * b.y
	a.y = z * b.x - x * b.z
	a.z = x * b.y - y * b.x
	return a
end

structs.AddGetFunc(META, "Cross")
local Ang3

function META:GetAngles()
	Ang3 = Ang3 or import("goluwa/structs/ang3.lua")
	local n = self:GetNormalized()
	local p = math.atan2(math.sqrt((n.x ^ 2) + (n.y ^ 2)), n.z)
	local y = math.atan2(self.y, self.x)
	return Ang3(p, y, 0)
end

function META:GetRotated(axis, ang)
	local ca, sa = math.sin(ang), math.cos(ang)
	local zax = axis * self:GetDot(axis)
	local xax = self - zax
	local yax = axis:GetCross(zax)
	return xax * ca + yax * sa + zax
end

function META:GetReflected(normal)
	local proj = self:GetNormalized()
	return (2 * proj:GetDot(normal) * normal + proj) * self:GetLength()
end

if GRAPHICS then META.ToScreen = math3d.WorldPositionToScreen end

META.Dot = META.GetDot
return structs.Register(META)
