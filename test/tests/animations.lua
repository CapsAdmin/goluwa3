local T = require("test.environment")
local animations = require("animations")
local Vec2 = require("structs.vec2")
local Ang3 = require("structs.ang3")

T.Test("animation override with spring and single target", function()
	local val = Ang3(0, 0, 0)
	local get = function()
		return val
	end
	local set = function(v)
		val = v
	end
	-- Start an animation
	animations.Animate(
		{
			id = "test",
			group = "test_group",
			get = get,
			set = set,
			to = Ang3(0, 0, 0), -- Redundant target
			interpolation = {type = "spring"},
			time = 1,
		}
	)
	-- Override it immediately
	-- This should not crash even if the first one was redundant
	animations.Animate(
		{
			id = "test",
			group = "test_group",
			get = get,
			set = set,
			to = Ang3(1, 1, 1),
			interpolation = {type = "spring"},
			time = 1,
		}
	)
	T(true)["=="](true) -- If we reached here, it didn't crash
end)

T.Test("animation override with cdata types", function()
	local val = Vec2(0, 0)
	local get = function()
		return val
	end
	local set = function(v)
		val = v
	end
	animations.Animate(
		{
			id = "test2",
			group = "test_group",
			get = get,
			set = set,
			to = Vec2(100, 100),
			time = 1,
		}
	)
	-- Manually update a bit
	animations.Update(0.1, "test_group")
	local mid_val = val:Copy()
	T(val.x > 0)["=="](true)
	-- Override
	animations.Animate(
		{
			id = "test2",
			group = "test_group",
			get = get,
			set = set,
			to = Vec2(200, 200),
			time = 1,
		}
	)
	-- The fix ensures that mid_val (which was 'val' at the time of override)
	-- is used as the starting point, instead of being mutated by the new animation initialization logic.
	T(val.x)["=="](mid_val.x)
	T(val.y)["=="](mid_val.y)
end)
