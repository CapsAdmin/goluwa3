local T = import("test/environment.lua")
local luadata = import("goluwa/codecs/luadata.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")

T.Test("Luadata round trips structs, nesting and special numbers", function()
	local source = {
		name = "a\nb \"q\"",
		fraction = 0.1,
		big = math.huge,
		list = {1, 2, 3},
		nested = {point = {position = Vec3(1, 2.5, -3)}, ["a key"] = true},
		rotation = Quat(0, 0, 0, 1),
		color = Color(1, 0.5, 0, 1),
		empty = {},
	}
	local text = luadata.Encode(source)
	local decoded = assert(luadata.Decode(text))
	T(decoded.name)["=="](source.name)
	T(decoded.fraction)["=="](0.1)
	T(decoded.big)["=="](math.huge)
	T(#decoded.list)["=="](3)
	T(decoded.nested.point.position)["=="](Vec3(1, 2.5, -3))
	T(decoded.nested["a key"])["=="](true)
	T(decoded.rotation)["=="](source.rotation)
	T(decoded.color)["=="](source.color)
	T(next(decoded.empty))["=="](nil)
	T(luadata.Encode(decoded))["=="](text)
end)

T.Test("Luadata encoding is deterministic regardless of insertion order", function()
	local a = {z = 1, a = 2, m = {y = 1, b = 2}}
	local b = {m = {b = 2, y = 1}, a = 2, z = 1}
	T(luadata.Encode(a))["=="](luadata.Encode(b))
end)

T.Test("Luadata decode is sandboxed", function()
	T(luadata.Decode("x = os.exit(1)"))["=="](nil)
end)
