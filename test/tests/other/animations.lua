local T = import("test/environment.lua")
local animations = import("goluwa/animations.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Ang3 = import("goluwa/structs/ang3.lua")

T.Test("animation override with spring and single target", function()
	local val = Ang3(0, 0, 0)
	local get = function()
		return val
	end
	local set = function(v)
		val = v
	end
	animations.Animate{
		id = "test",
		group = "test_group",
		get = get,
		set = set,
		to = Ang3(0, 0, 0),
		interpolation = {type = "spring"},
		time = 1,
	}
	animations.Animate{
		id = "test",
		group = "test_group",
		get = get,
		set = set,
		to = Ang3(1, 1, 1),
		interpolation = {type = "spring"},
		time = 1,
	}
	T(true)["=="](true)
end)

T.Test("animation override with cdata types", function()
	local val = Vec2(0, 0)
	local get = function()
		return val
	end
	local set = function(v)
		val = v
	end
	animations.Animate{
		id = "test2",
		group = "test_group",
		get = get,
		set = set,
		to = Vec2(100, 100),
		time = 1,
	}
	animations.Update(0.1, "test_group")
	local mid_val = val:Copy()
	T(val.x > 0)["=="](true)
	animations.Animate{
		id = "test2",
		group = "test_group",
		get = get,
		set = set,
		to = Vec2(200, 200),
		time = 1,
	}
	T(val.x)["=="](mid_val.x)
	T(val.y)["=="](mid_val.y)
end)
