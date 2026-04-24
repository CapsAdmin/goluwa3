local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

local function add_triangle(poly, p1, p2, p3, uv1, uv2, uv3, n1, n2, n3)
	local face_normal = (p2 - p1):GetCross(p3 - p1):GetNormalized()
	poly:AddVertex{pos = p1, uv = uv1 or Vec2(0, 0), normal = n1 or face_normal}
	poly:AddVertex{pos = p2, uv = uv2 or Vec2(1, 0), normal = n2 or face_normal}
	poly:AddVertex{pos = p3, uv = uv3 or Vec2(1, 1), normal = n3 or face_normal}
end

return {
	name = "cone",
	kind = "procedural_model",
	bounds = {radius = 0.5, height = 1},
	create_primitives = function(options)
		options = options or {}
		local radius = options.radius or 0.5
		local height = options.height or 1
		local segments = options.segments or 24
		local poly = Polygon3D.New()
		local apex = Vec3(0, height * 0.5, 0)
		local base_center = Vec3(0, -height * 0.5, 0)

		for index = 0, segments - 1 do
			local fraction1 = index / segments
			local fraction2 = (index + 1) / segments
			local angle1 = fraction1 * math.pi * 2
			local angle2 = fraction2 * math.pi * 2
			local p1 = Vec3(math.cos(angle1) * radius, -height * 0.5, math.sin(angle1) * radius)
			local p2 = Vec3(math.cos(angle2) * radius, -height * 0.5, math.sin(angle2) * radius)
			local n1 = Vec3(p1.x, radius, p1.z):GetNormalized()
			local n2 = Vec3(p2.x, radius, p2.z):GetNormalized()
			local napex = Vec3((n1.x + n2.x) * 0.5, radius, (n1.z + n2.z) * 0.5):GetNormalized()
			add_triangle(
				poly,
				apex,
				p1,
				p2,
				Vec2(0.5, 0),
				Vec2(fraction1, 1),
				Vec2(fraction2, 1),
				napex,
				n1,
				n2
			)
			add_triangle(
				poly,
				base_center,
				p2,
				p1,
				Vec2(0.5, 0.5),
				Vec2((math.cos(angle2) + 1) * 0.5, (math.sin(angle2) + 1) * 0.5),
				Vec2((math.cos(angle1) + 1) * 0.5, (math.sin(angle1) + 1) * 0.5),
				Vec3(0, -1, 0),
				Vec3(0, -1, 0),
				Vec3(0, -1, 0)
			)
		end

		poly:BuildBoundingBox()
		poly:Upload()
		return {
			{mesh = poly},
		}
	end,
}
