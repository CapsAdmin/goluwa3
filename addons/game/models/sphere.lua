local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local meshes = {}
return {
	name = "sphere",
	kind = "procedural_model",
	bounds = {radius = 0.5},
	create_primitives = function(options)
		options = options or {}
		local segments = options.segments or 64
		local rings = options.rings or 32
		local key = segments .. "x" .. rings
		local poly = meshes[key]

		if not poly then
			poly = Polygon3D.New()
			shapes.BuildSphere(poly, 0.5, segments, rings)
			poly:BuildBoundingBox()
			poly:Upload()
			meshes[key] = poly
		end

		local diameter = (options.radius or 0.5) * 2
		return {
			{mesh = poly, scale = Vec3(diameter, diameter, diameter)},
		}
	end,
}
