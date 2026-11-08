local T = import("test/environment.lua")
local luadata = import("goluwa/codecs/luadata.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec4 = import("goluwa/structs/vec4.lua")
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
		transform = Vec4(1, 0, 0.5, 2),
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
	T(decoded.transform)["=="](source.transform)
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

T.Test("Luadata encodes as a lua chunk that decodes and loads", function()
	local source = {
		name = "x",
		position = Vec3(1, 2, 3),
		list = {1, 2},
		nested = {color = Color(1, 0, 0, 1)},
	}
	local text = luadata.Encode(source, true)
	T(text:find("^return {") ~= nil)["=="](true)
	local decoded = assert(luadata.Decode(text))
	T(decoded.position)["=="](Vec3(1, 2, 3))
	T(decoded.nested.color)["=="](Color(1, 0, 0, 1))
	T(luadata.Decode("return {x = os.exit(1)}"))["=="](nil)
	local chunk = assert(loadstring(text))
	setfenv(chunk, {Vec3 = Vec3, Color = Color})
	T(chunk().position)["=="](Vec3(1, 2, 3))
end)

T.Test("Luadata writes multiline strings as long brackets and reads them back exactly", function()
	local cases = {
		"one\ntwo",
		"\nstarts with a newline",
		"ends with a newline\n",
		"has ]] inside\nand ]=] too",
		"ends with a bracket\n]",
		"tab\tand \"quotes\" and \\ backslash\nline",
		"carriage\r\nreturn",
		"nul\0byte\nline",
		"single line",
	}

	for _, value in ipairs(cases) do
		local text = luadata.Encode({value = value}, true)
		T(assert(luadata.Decode(text)).value)["=="](value)
	end

	T(luadata.Encode({value = "a\nb"}, true):find("[[a\nb]]", 1, true) ~= nil)["=="](true)
	T(luadata.Encode({value = "a b"}, true):find("\"a b\"", 1, true) ~= nil)["=="](true)
	T(luadata.Encode({value = "a\r\nb"}, true):find("[[", 1, true))["=="](nil)
end)

T.Test("Luadata encodes struct components that no short float string round trips", function()
	local value = -426217040.14187968
	local text = luadata.Encode({position = Vec3(value, 1, 2), color = Color(1, 2, 3, 166.66666666666)}, true)
	local decoded = assert(luadata.Decode(text))
	T(math.abs(decoded.position.x - value) < 64)["=="](true)
	T(math.abs(decoded.color.a - 166.66666666666) < 0.001)["=="](true)
end)
