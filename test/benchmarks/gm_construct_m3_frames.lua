-- glw: --3d --background
local commands = import("goluwa/cli/commands.lua")
local frame_benchmark = import("goluwa/render3d/frame_benchmark.lua")
local pvars = import("goluwa/cli/pvars.lua")
local units = import("goluwa/source_engine/units.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

local function set_mode(culling, lod_level)
	return function()
		pvars.SetSession("r_feature_culling", culling)
		pvars.SetSession("lod_level", lod_level)
	end
end

frame_benchmark.Run{
	name = "gm_construct_m3",
	load = function()
		commands.RunString("map gm_construct_m3_401")
	end,
	view = function()
		return units.PositionToEngine(Vec3(-10818, -9029.5, 9448)), 0, 0
	end,
	phases = {
		{name = "culled", enter = set_mode(true, -1)},
		{name = "unculled", enter = set_mode(false, -1)},
		{name = "unculled lod 0", enter = set_mode(false, 0)},
		{name = "culled again", enter = set_mode(true, -1)},
	},
}
