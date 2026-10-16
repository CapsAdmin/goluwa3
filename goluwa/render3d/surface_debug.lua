local pvars = import("goluwa/cli/pvars.lua")
local surface_debug = {}
surface_debug.MODES = {"off", "vertex", "map", "combined", "albedo", "terrain"}
surface_debug.VERTEX = 1
surface_debug.MAP = 2
surface_debug.COMBINED = 3
surface_debug.ALBEDO = 4
pvars.StartGroup("Rendering", "Surface", {store = false})
local view = pvars.Setup2{
	key = "r_surface_debug",
	default = "off",
	enums = surface_debug.MODES,
	help = "show surfaces stripped of a layer of shading. normals: vertex is the interpolated vertex normal, map is the tangent space normal map, combined is the final normal, world space except for map. albedo is the surface color without any lighting, fog or tonemapping. terrain is albedo with the terrain layers left out, only the terrain's own base color",
}
pvars.EndGroup()
local mode_index = {off = 0, vertex = 1, map = 2, combined = 3, albedo = 4, terrain = 4}

-- the gbuffer value the debug pass shows as a color, 0 when it shows none
function surface_debug.GetView()
	return mode_index[view:Get()]
end

function surface_debug.GetTerrainOnly()
	return view:Get() == "terrain"
end

return surface_debug
