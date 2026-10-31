local T = import("test/environment.lua")
local screen_fields = import("goluwa/render3d/screen_fields.lua")
local event = import("goluwa/event.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

local function step(dt)
	event.Call("Update", dt)
end

T.Test("a screen field expands, peaks quickly and is removed when its duration is over", function()
	screen_fields.Clear()
	local field = screen_fields.Add{Position = Vec3(0, 1, 0), Duration = 1, Radius = 8, Attack = 0.1}
	T(screen_fields.IsActive())["=="](true)
	T(screen_fields.GetRadius(field))["=="](0)
	step(0.1)
	T(screen_fields.GetIntensity(field))["~"](1, 1e-6)
	T(screen_fields.GetRadius(field) > 8 * 0.2)["=="](true)
	step(0.8)
	T(screen_fields.GetIntensity(field) < 0.05)["=="](true)
	step(0.2)
	T(screen_fields.IsActive())["=="](false)
end)

T.Test("a field that does not expand keeps its radius and the oldest field is dropped past the limit", function()
	screen_fields.Clear()
	local dome = screen_fields.Add{Position = Vec3(), Duration = 5, Radius = 3, Expand = false}
	T(screen_fields.GetRadius(dome))["=="](3)

	for _ = 1, screen_fields.MAX do
		screen_fields.Add{Position = Vec3(), Duration = 5}
	end

	T(#screen_fields.fields)["=="](screen_fields.MAX)
	T(table.has_value(screen_fields.fields, dome))["=="](false)
	screen_fields.Clear()
	T(screen_fields.IsActive())["=="](false)
end)
