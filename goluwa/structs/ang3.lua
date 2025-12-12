local Vec3 = require("structs.vec3")
local structs = require("structs.structs")
local orientation = require("orientation")
local META = structs.Template("Ang3")
local CTOR

function Deg3(p, y, r)
	return CTOR(p, y, r):Rad()
end

META.Args = {{"x", "y", "z"}, {"p", "y", "r"}, {"pitch", "yaw", "roll"}}
structs.AddAllOperators(META)

do -- ORIENTATION / TRANSFORMATION
	local sin = math.sin
	local cos = math.cos

	-- Coordinate system defined in orientation.lua
	-- a.x = pitch (rotation around pitch axis)
	-- a.y = yaw (rotation around yaw axis)
	-- a.z = roll (rotation around roll axis)
	-- Transform a direction vector by these angles using Euler rotation (no quat overhead)
	-- ORIENTATION / TRANSFORMATION: Applies rotations in order: yaw (Y), pitch (X), roll (Z)
	-- This matches the view matrix rotation order for consistent camera behavior
	function META.GetDirection(a, x, y, z)
		if type(x) == "table" or type(x) == "cdata" then
			x, y, z = x.x or x[1], x.y or x[2], x.z or x[3]
		end

		local sy, cy = sin(a.y), cos(a.y)
		local sp, cp = sin(-a.x), cos(-a.x) -- Negate pitch for correct up/down
		local sr, cr = sin(a.z), cos(a.z)
		-- Apply yaw rotation (around Y axis)
		local yx = x * cy + z * sy
		local yy = y
		local yz = -x * sy + z * cy
		-- Apply pitch rotation (around X axis)
		local px = yx
		local py = yy * cp - yz * sp
		local pz = yy * sp + yz * cp
		-- Apply roll rotation (around Z axis)
		local rx = px * cr - py * sr
		local ry = px * sr + py * cr
		local rz = pz
		return Vec3(rx, ry, rz)
	end -- Use GetDirection with orientation module vectors for convenience
	function META.GetForward(a)
		return a:GetDirection(orientation.GetForwardVector())
	end

	function META.GetUp(a)
		return a:GetDirection(orientation.GetUpVector())
	end

	function META.GetRight(a)
		return a:GetDirection(orientation.GetRightVector())
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
