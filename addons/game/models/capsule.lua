local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

local function add_triangle(poly, p1, p2, p3, uv1, uv2, uv3, n1, n2, n3)
	local face_normal = (p2 - p1):GetCross(p3 - p1):GetNormalized()
	poly:AddVertex{pos = p1, uv = uv1 or Vec2(0, 0), normal = n1 or face_normal}
	poly:AddVertex{pos = p2, uv = uv2 or Vec2(1, 0), normal = n2 or face_normal}
	poly:AddVertex{pos = p3, uv = uv3 or Vec2(1, 1), normal = n3 or face_normal}
end

local function add_capsule_hemisphere(poly, center_y, radius, theta_start, theta_end, segments, rings)
	for ring = 0, rings - 1 do
		local theta1 = theta_start + ((ring / rings) * (theta_end - theta_start))
		local theta2 = theta_start + (((ring + 1) / rings) * (theta_end - theta_start))

		for seg = 0, segments - 1 do
			local phi1 = (seg / segments) * math.pi * 2
			local phi2 = ((seg + 1) / segments) * math.pi * 2

			local function point(theta, phi)
				local x = radius * math.sin(theta) * math.sin(phi)
				local y = radius * math.cos(theta)
				local z = radius * math.sin(theta) * math.cos(phi)
				return Vec3(x, center_y + y, z), Vec3(x, y, z):GetNormalized()
			end

			local p1, n1 = point(theta1, phi1)
			local p2, n2 = point(theta1, phi2)
			local p3, n3 = point(theta2, phi2)
			local p4, n4 = point(theta2, phi1)
			local u1 = 0.75 - (seg / segments)
			local u2 = 0.75 - ((seg + 1) / segments)
			local v1 = ring / rings
			local v2 = (ring + 1) / rings

			if ring > 0 or theta_start > 0 then
				add_triangle(poly, p1, p2, p3, Vec2(u1, v1), Vec2(u2, v1), Vec2(u2, v2), n1, n2, n3)
			end

			if ring < rings - 1 or theta_end < math.pi then
				add_triangle(poly, p1, p3, p4, Vec2(u1, v1), Vec2(u2, v2), Vec2(u1, v2), n1, n3, n4)
			end
		end
	end
end

return {
	name = "capsule",
	kind = "procedural_model",
	bounds = {radius = 0.25, total_height = 1},
	create_primitives = function(options)
		options = options or {}
		local radius = options.radius or 0.25
		local total_height = math.max(options.height or 1, radius * 2)
		local cylinder_height = math.max(total_height - radius * 2, 0)
		local cylinder_half_height = cylinder_height * 0.5
		local segments = options.segments or 20
		local rings = options.rings or 8
		local poly = Polygon3D.New()

		for index = 0, segments - 1 do
			local fraction1 = index / segments
			local fraction2 = (index + 1) / segments
			local angle1 = fraction1 * math.pi * 2
			local angle2 = fraction2 * math.pi * 2
			local x1 = math.cos(angle1) * radius
			local z1 = math.sin(angle1) * radius
			local x2 = math.cos(angle2) * radius
			local z2 = math.sin(angle2) * radius
			local n1 = Vec3(x1, 0, z1):GetNormalized()
			local n2 = Vec3(x2, 0, z2):GetNormalized()
			local bottom1 = Vec3(x1, -cylinder_half_height, z1)
			local bottom2 = Vec3(x2, -cylinder_half_height, z2)
			local top1 = Vec3(x1, cylinder_half_height, z1)
			local top2 = Vec3(x2, cylinder_half_height, z2)
			add_triangle(
				poly,
				top1,
				bottom1,
				bottom2,
				Vec2(fraction1, 0),
				Vec2(fraction1, 1),
				Vec2(fraction2, 1),
				n1,
				n1,
				n2
			)
			add_triangle(
				poly,
				top1,
				bottom2,
				top2,
				Vec2(fraction1, 0),
				Vec2(fraction2, 1),
				Vec2(fraction2, 0),
				n1,
				n2,
				n2
			)
		end

		add_capsule_hemisphere(poly, cylinder_half_height, radius, 0, math.pi * 0.5, segments, rings)
		add_capsule_hemisphere(poly, -cylinder_half_height, radius, math.pi * 0.5, math.pi, segments, rings)
		poly:BuildBoundingBox()
		poly:Upload()
		return {
			{mesh = poly},
		}
	end,
}
