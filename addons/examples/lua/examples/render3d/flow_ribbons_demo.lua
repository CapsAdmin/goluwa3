local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local flow_ribbons = import("goluwa/render3d/flow_ribbons.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local demo = {}
local INTERVAL = 2.6
local LOOKS = {
	{color = Color(1, 0.45, 0.1, 1), core = Color(1, 0.9, 0.7, 1)},
	{color = Color(0.25, 0.55, 1, 1), core = Color(0.8, 0.95, 1, 1)},
	{color = Color(0.5, 1, 0.35, 1), core = Color(0.9, 1, 0.8, 1)},
	{color = Color(0.85, 0.3, 1, 1), core = Color(1, 0.85, 1, 1)},
}
test_scene.Reset{sun = {elevation = test_scene.GetNumber("FLOW_SUN", -6), azimuth = 200}}
shapes.Box{
	Name = "flow_ribbons_floor",
	Parent = test_scene.GetRoot(),
	Position = Vec3(0, -0.5, 0),
	Size = Vec3(60, 1, 60),
	Material = shapes.Material{Color = Color(0.25, 0.25, 0.27, 1), Roughness = 0.6},
	RigidBody = {MotionType = "static"},
}
local last = -math.huge
local count = 0

event.AddListener("Update", "flow_ribbons_demo", function()
	local now = system.GetElapsedTime()

	if now - last < INTERVAL then return end

	last = now
	count = count + 1
	local look = LOOKS[count % #LOOKS + 1]
	flow_ribbons.Burst{position = Vec3(0, 0, 0), color = look.color, core = look.core}
end)

return demo
