local T = require("test.environment")
local Vec3 = require("structs.vec3")

T.Test("Vec3 construction", function()
	local v = Vec3(1, 2, 3)
	T(v.x)["=="](1)
	T(v.y)["=="](2)
	T(v.z)["=="](3)
end)

T.Test("Vec3 default construction", function()
	T(Vec3())["=="](Vec3(0, 0, 0))
end)

T.Test("Vec3 copy", function()
	local v1 = Vec3(1, 2, 3)
	local v2 = v1:Copy()
	T(v2.x)["=="](1)
	T(v2.y)["=="](2)
	T(v2.z)["=="](3)
	v2.x = 10
	T(v1.x)["=="](1)
end)

T.Test("Vec3 addition", function()
	T(Vec3(1, 2, 3) + Vec3(4, 5, 6))["=="](Vec3(5, 7, 9))
end)

T.Test("Vec3 subtraction", function()
	T(Vec3(5, 7, 9) - Vec3(1, 2, 3))["=="](Vec3(4, 5, 6))
end)

T.Test("Vec3 scalar multiplication", function()
	T(Vec3(1, 2, 3) * 2)["=="](Vec3(2, 4, 6))
end)

T.Test("Vec3 scalar division", function()
	T(Vec3(2, 4, 6) / 2)["=="](Vec3(1, 2, 3))
end)

T.Test("Vec3 dot product", function()
	T(Vec3(1, 2, 3):GetDot(Vec3(4, 5, 6)))["=="](32)
end)

T.Test("Vec3 cross product", function()
	T(Vec3(1, 0, 0):GetCross(Vec3(0, 1, 0)))["=="](Vec3(0, 0, 1))
end)

T.Test("Vec3 cross product - inverse order", function()
	T(Vec3(0, 1, 0):GetCross(Vec3(1, 0, 0)))["=="](Vec3(0, 0, -1))
end)

T.Test("Vec3 length", function()
	T(Vec3(3, 4, 0):GetLength())["~"](5)
end)

T.Test("Vec3 length 3D", function()
	T(Vec3(1, 2, 2):GetLength())["~"](3)
end)

T.Test("Vec3 normalize", function()
	local v = Vec3(3, 4, 0)
	local n = v:GetNormalized()
	T(n.x)["~"](0.6)
	T(n.y)["~"](0.8)
	T(n.z)["~"](0)
	T(n:GetLength())["~"](1)
end)

T.Test("Vec3 negation", function()
	local v = Vec3(1, -2, 3)
	local neg = -v
	T(neg.x)["=="](-1)
	T(neg.y)["=="](2)
	T(neg.z)["=="](-3)
end)

T.Test("Vec3 equality", function()
	local v1 = Vec3(1, 2, 3)
	local v2 = Vec3(1, 2, 3)
	local v3 = Vec3(1, 2, 4)
	T(v1)["=="](v2)
	T(v1)["~="](v3)
end)

T.Test("Vec3 GetAngles", function()
	local v = Vec3(1, 0, 0)
	T(v:GetAngles())["~="](nil)
end)
