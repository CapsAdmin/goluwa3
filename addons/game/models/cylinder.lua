local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

local function add_triangle(poly, p1, p2, p3, uv1, uv2, uv3, n1, n2, n3)
	poly:AddVertex{pos = p1, uv = uv1, normal = n1}
	poly:AddVertex{pos = p2, uv = uv2, normal = n2}
	poly:AddVertex{pos = p3, uv = uv3, normal = n3}
end

return {
	name = "cylinder",
	kind = "procedural_model",
	bounds = {radius = 0.5, total_height = 1},
	create_primitives = function(options)
		options = options or {}
		local radius = options.radius or 0.5
		local half = (options.height or 1) / 2
		local segments = options.segments or 20
		local poly = Polygon3D.New()
		local up = Vec3(0, 1, 0)
		local down = Vec3(0, -1, 0)

		for index = 0, segments - 1 do
			local f1, f2 = index / segments, (index + 1) / segments
			local a1, a2 = f1 * math.pi * 2, f2 * math.pi * 2
			local x1, z1 = math.cos(a1) * radius, math.sin(a1) * radius
			local x2, z2 = math.cos(a2) * radius, math.sin(a2) * radius
			local n1, n2 = Vec3(x1, 0, z1):GetNormalized(), Vec3(x2, 0, z2):GetNormalized()
			local top1, top2 = Vec3(x1, half, z1), Vec3(x2, half, z2)
			local bottom1, bottom2 = Vec3(x1, -half, z1), Vec3(x2, -half, z2)
			add_triangle(poly, top1, bottom1, bottom2, Vec2(f1, 0), Vec2(f1, 1), Vec2(f2, 1), n1, n1, n2)
			add_triangle(poly, top1, bottom2, top2, Vec2(f1, 0), Vec2(f2, 1), Vec2(f2, 0), n1, n2, n2)
			add_triangle(
				poly,
				Vec3(0, half, 0),
				top2,
				top1,
				Vec2(0.5, 0.5),
				Vec2(0.5, 0.5),
				Vec2(0.5, 0.5),
				up,
				up,
				up
			)
			add_triangle(
				poly,
				Vec3(0, -half, 0),
				bottom1,
				bottom2,
				Vec2(0.5, 0.5),
				Vec2(0.5, 0.5),
				Vec2(0.5, 0.5),
				down,
				down,
				down
			)
		end

		poly:BuildBoundingBox()
		poly:Upload()
		return {{mesh = poly}}
	end,
}
