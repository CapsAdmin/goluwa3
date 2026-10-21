local T = import("test/environment.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

local function winding_dot(poly, first)
	local a, b, c = poly.Vertices[first].pos, poly.Vertices[first + 1].pos, poly.Vertices[first + 2].pos
	local geometric = (c - a):GetCross(b - a):GetNormalized()
	return geometric:GetDot(poly.Vertices[first].normal)
end

T.Test("shapes plane faces the normal it is given", function()
	local normals = {
		Vec3(0, 1, 0),
		Vec3(0, -1, 0),
		Vec3(0, 0, 1),
		Vec3(0, 0, -1),
		Vec3(1, 0, 0),
		Vec3(-1, 0, 0),
		Vec3(1, 2, 3):GetNormalized(),
	}

	for _, normal in ipairs(normals) do
		local poly = Polygon3D.New()
		shapes.BuildPlane(poly, Vec3(0, 0, 0), normal, 1, 1)
		T(#poly.Vertices)["=="](6)

		for first = 1, 4, 3 do
			T(winding_dot(poly, first))[">"](0.999)
			local vertex = poly.Vertices[first]
			T(vertex.normal:GetDot(normal))[">"](0.999)
		end
	end
end)

T.Test("shapes cube faces point away from the center", function()
	local poly = Polygon3D.New()
	shapes.BuildCube(poly, 1)
	T(#poly.Vertices)["=="](36)

	for first = 1, 34, 3 do
		local vertex = poly.Vertices[first]
		T(vertex.pos:GetDot(vertex.normal))[">"](0.999)
		T(winding_dot(poly, first))[">"](0.999)
	end
end)

local function check_lathe(poly, scale)
	local checked = 0

	for first = 1, #poly.Vertices - 2, 3 do
		local a, b, c = poly.Vertices[first].pos, poly.Vertices[first + 1].pos, poly.Vertices[first + 2].pos
		local geometric = (c - a):GetCross(b - a)

		if geometric:GetLength() > 1e-6 then
			for corner = 0, 2 do
				local normal = poly.Vertices[first + corner].normal
				T(normal:GetLength())[">"](0.999)
				T(geometric:GetNormalized():GetDot(normal))[">"](0.8)
			end

			checked = checked + 1
		end
	end

	return checked
end

T.Test("shapes lathe makes a closed cylinder that faces outwards", function()
	local poly = Polygon3D.New()
	shapes.BuildLathe(poly, {{0, 0}, {1, 0}, {1, 2}, {0, 2}}, 12)
	T(#poly.Vertices)["=="](3 * 2 * 12 * 3)
	T(check_lathe(poly))["=="](48)

	for _, vertex in ipairs(poly.Vertices) do
		if vertex.pos.y > 0.01 and vertex.pos.y < 1.99 then
			T(vertex.normal.y)["=="](0)
			T(vertex.normal:GetDot(Vec3(vertex.pos.x, 0, vertex.pos.z)))[">"](0.999)
		end
	end
end)

T.Test("shapes lathe keeps normals right when it is stretched", function()
	local profile = {}

	for i = 0, 24 do
		local angle = i / 24 * math.pi
		profile[#profile + 1] = {math.sin(angle), -math.cos(angle)}
	end

	local scale = Vec3(2, 0.8, 1.5)
	local poly = Polygon3D.New()
	shapes.BuildLathe(poly, profile, 16, 1, scale)
	T(check_lathe(poly))[">"](300)

	for _, vertex in ipairs(poly.Vertices) do
		local p = vertex.pos
		local expected = Vec3(p.x / scale.x ^ 2, p.y / scale.y ^ 2, p.z / scale.z ^ 2):GetNormalized()

		if math.abs(p.y) < 0.7 then T(vertex.normal:GetDot(expected))[">"](0.98) end
	end
end)

T.Test3D("shapes materials default to a dull dielectric", function()
	local plain = shapes.Material()
	T(plain:GetMetallicMultiplier())["=="](0)
	T(plain:GetRoughnessMultiplier())["=="](0.6)
	local explicit = shapes.Material{MetallicMultiplier = 1, RoughnessMultiplier = 0.1}
	T(explicit:GetMetallicMultiplier())["=="](1)
	T(explicit:GetRoughnessMultiplier())["=="](0.1)
end)
