local T = import("test/environment.lua")
local Beam = import("goluwa/render3d/beam.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")

T.Test3D("A beam follows its points, bends and keeps its radius", function()
	local beam = Beam.New{
		Points = 9,
		Radius = 0.1,
		Material = Beam.CreateMaterial(Color(0.2, 0.5, 1), 10),
	}
	local points = Beam.NewPoints(9)
	Beam.Line(Vec3(0, 1, 0), Vec3(0, 1, -8), points)
	beam:SetPoints(points)
	local vertices = beam.polygon.Vertices
	local first = vertices[1].pos
	T(math.abs(first:Distance(points[1]) - 0.1))["<"](1e-5)
	local aabb = beam.polygon.AABB
	T(aabb.min_z)["<="](-8)
	Beam.Quadratic(Vec3(0, 1, 0), Vec3(0, 1, -4), Vec3(3, 1, -4), points)
	beam:SetPoints(points)
	T(math.abs(points[5].x))[">"](0.1)
	T(math.abs(vertices[5 * 7 + 1].pos:Distance(points[6]) - 0.1))["<"](1e-5)
	T(beam.polygon.AABB.max_x)[">="](3)
	T(#beam.entity.visual:GetRenderEntries())["=="](1)
	beam:SetVisible(false)
	T(beam.entity.visual:GetVisible())["=="](false)
	beam:Remove()
end)
