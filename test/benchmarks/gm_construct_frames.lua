local commands = import("goluwa/cli/commands.lua")
local frame_benchmark = import("goluwa/render3d/frame_benchmark.lua")
local raycast = import("goluwa/render3d/raycast.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
frame_benchmark.Run{
	name = "gm_construct",
	load = function()
		commands.RunString("map gm_construct")
	end,
	view = function()
		local hit = raycast.CastClosest(Vec3(0, 60, 0), Vec3(0, -1, 0), 200)
		local floor_y = hit and hit.position.y or 0
		return Vec3(0, floor_y + 1.7, 0), -5, 0
	end,
}
