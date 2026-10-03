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

T.Test3D("shapes materials default to a dull dielectric", function()
	local plain = shapes.Material()
	T(plain:GetMetallicMultiplier())["=="](0)
	T(plain:GetRoughnessMultiplier())["=="](0.6)
	local explicit = shapes.Material{MetallicMultiplier = 1, RoughnessMultiplier = 0.1}
	T(explicit:GetMetallicMultiplier())["=="](1)
	T(explicit:GetRoughnessMultiplier())["=="](0.1)
end)
