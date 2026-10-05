local pvars = import("goluwa/cli/pvars.lua")
local normal_debug = library()
normal_debug.MODES = {"off", "vertex", "map", "combined"}
normal_debug.VERTEX = 1
normal_debug.MAP = 2
normal_debug.COMBINED = 3
pvars.StartGroup("normal_debug", {store = false})
local view = pvars.Setup2{
	key = "r_normal_debug",
	default = "off",
	enums = normal_debug.MODES,
	help = "show only the surface normal as color: vertex is the interpolated vertex normal, map is the tangent space normal map, combined is the final normal. world space except for map",
}
pvars.EndGroup()
local mode_index = {off = 0, vertex = 1, map = 2, combined = 3}

function normal_debug.GetView()
	return mode_index[view:Get()]
end

return normal_debug
