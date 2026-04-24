local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
return {
	name = "box",
	kind = "procedural_model",
	bounds = {half_extents = Vec3(0.5, 0.5, 0.5)},
	create_primitives = function(options)
		options = options or {}
		local size = options.size or Vec3(1, 1, 1)
		local poly = Polygon3D.New()
		poly:CreateCube(0.5)
		poly:BuildBoundingBox()
		poly:Upload()
		return {
			{mesh = poly, scale = size},
		}
	end,
}
