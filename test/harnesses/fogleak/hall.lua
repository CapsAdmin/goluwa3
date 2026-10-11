local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local L = test_scene.GetNumber("HALL_L", 80)
local W = test_scene.GetNumber("HALL_W", 16)
local H = test_scene.GetNumber("HALL_H", 120)
local t = 0.5
test_scene.Reset{sun = {elevation = 45, azimuth = 30}}
test_scene.Room{
	pos = Vec3(0, 0, -L / 2),
	size = Vec3(W, H, L),
	thickness = t,
	material = test_scene.Matte(Color(0.05, 0.04, 0.035, 1), 0.95),
}
test_scene.Ground{top = -t}
local fog = test_scene.GetNumber("FOG_DENSITY", nil)

if fog then import("goluwa/render3d/atmosphere.lua").fog_density = fog end
