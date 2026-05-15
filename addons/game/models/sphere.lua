local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
return {
	name = "sphere",
	kind = "procedural_model",
	bounds = {radius = 0.5},
	create_primitives = function(options)
		options = options or {}
		local radius = options.radius or 0.5
		local poly = Polygon3D.New()
		poly:CreateSphere(radius, options.segments or 16, options.rings or 12)
		poly:BuildBoundingBox()
		poly:Upload()
		return {
			{mesh = poly},
		}
	end,
}
