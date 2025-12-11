local Vec3 = require("structs.vec3")
local structs = require("structs.structs")
local META = structs.Template("Ang3")
local CTOR

function Deg3(p, y, r)
	return CTOR(p, y, r):Rad()
end

META.Args = {{"x", "y", "z"}, {"p", "y", "r"}, {"pitch", "yaw", "roll"}}
structs.AddAllOperators(META)

do
	local sin = math.sin
	local cos = math.cos

	-- Y-up, X-right, Z-forward coordinate system
	-- a.x = pitch (rotation around X axis)
	-- a.y = yaw (rotation around Y axis)
	-- a.z = roll (rotation around Z axis)
	function META.GetForward(a)
		return Vec3(sin(a.y) * cos(a.x), -sin(a.x), cos(a.y) * cos(a.x))
	end

	function META.GetUp(a)
		return Vec3(
			-sin(a.y) * sin(a.x) * cos(a.z) - cos(a.y) * sin(a.z),
			cos(a.x) * cos(a.z),
			-cos(a.y) * sin(a.x) * cos(a.z) + sin(a.y) * sin(a.z)
		)
	end

	function META.GetRight(a)
		return Vec3(
			sin(a.y) * sin(a.x) * sin(a.z) - cos(a.y) * cos(a.z),
			cos(a.x) * sin(a.z),
			cos(a.y) * sin(a.x) * sin(a.z) + sin(a.y) * cos(a.z)
		)
	end
end

local PI1 = math.pi
local PI2 = math.pi * 2

local function normalize(a)
	return (a + PI1) % PI2 - PI1
end

function META:Normalize()
	self.x = normalize(self.x)
	self.y = normalize(self.y)
	self.z = normalize(self.z)
	return self
end

structs.AddGetFunc(META, "Normalize", "Normalized")

function META.AngleDifference(a, b)
	a.x = normalize(a.x - b.x)
	a.y = normalize(a.y - b.y)
	a.z = normalize(a.z - b.z)
	a.x = a.x < PI2 and a.x or a.x - PI2
	a.y = a.y < PI2 and a.y or a.y - PI2
	a.z = a.z < PI2 and a.z or a.z - PI2
	return a
end

structs.AddGetFunc(META, "AngleDifference")

function META.Lerp(a, mult, b)
	a.x = (b.x - a.x) * mult + a.x
	a.y = (b.y - a.y) * mult + a.y
	a.z = (b.z - a.z) * mult + a.z
	a:Normalize()
	return a
end

structs.AddGetFunc(META, "Lerp", "Lerped")

function META:Rad()
	self.x = math.rad(self.x)
	self.y = math.rad(self.y)
	self.z = math.rad(self.z)
	return self
end

structs.AddGetFunc(META, "Rad")

function META:Deg()
	self.x = math.deg(self.x)
	self.y = math.deg(self.y)
	self.z = math.deg(self.z)
	return self
end

structs.AddGetFunc(META, "Deg")

-- LOL
function META:RotateAroundAxis2(axis, rad, how)
	local mat = Matrix44():SetRotation(Quat():SetAngles(self))
	mat:Rotate(rad, axis:Unpack())
	self:Set(mat:GetRotation():GetAngles(how):Unpack())
	return self
end

function META:RotateAroundAxis(axis, rad, how)
	local a = QuatFromAxis(rad, axis)
	local b = Quat():SetAngles(self)
	local q = a * b
	--q:Normalize()
	self:Set(q:GetAngles(how):Unpack())
	return self
end

CTOR = structs.Register(META)
return CTOR
