local commands = import("goluwa/cli/commands.lua")
local frame_benchmark = import("goluwa/render3d/frame_benchmark.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
frame_benchmark.Run{
	name = "Crysis PS/Beach",
	settle_quiet = 20,
	warmup = 12,
	load = function()
		commands.RunString("crymap PS/Beach")
	end,
	view = function()
		local min, max = scene_bvh.GetBounds()
		return Vec3((min[0] + max[0]) / 2, (min[1] + max[1]) / 2 + 150, (min[2] + max[2]) / 2),
		-10,
		0
	end,
	phases = {
		{name = "static"},
		{name = "rotating 30 deg/s", yaw_speed = 30},
		{name = "rotating 90 deg/s", yaw_speed = 90},
		{name = "moving 20 m/s", speed = 20, travel = 400},
		{name = "moving 40 m/s", speed = 40, travel = 400},
	},
}
