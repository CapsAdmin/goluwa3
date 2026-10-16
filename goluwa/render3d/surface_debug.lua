local pvars = import("goluwa/cli/pvars.lua")
local surface_debug = {}
surface_debug.MODES = {"off", "vertex", "map", "combined", "albedo"}
surface_debug.VERTEX = 1
surface_debug.MAP = 2
surface_debug.COMBINED = 3
surface_debug.ALBEDO = 4
pvars.StartGroup("Rendering", "Surface", {store = false})
local view = pvars.Setup2{
	key = "r_surface_debug",
	default = "off",
	enums = surface_debug.MODES,
	help = "show only one gbuffer value as color. normals: vertex is the interpolated vertex normal, map is the tangent space normal map, combined is the final normal, world space except for map. albedo is the surface color without any lighting, fog or tonemapping",
}
pvars.EndGroup()
local mode_index = {off = 0, vertex = 1, map = 2, combined = 3, albedo = 4}

function surface_debug.GetView()
	return mode_index[view:Get()]
end

return surface_debug
