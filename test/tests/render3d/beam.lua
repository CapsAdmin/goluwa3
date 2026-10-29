local T = import("test/environment.lua")
local Beam = import("goluwa/render3d/beam.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local vfx = import("goluwa/render3d/vfx.lua")
local surface_overlays = import("goluwa/render3d/surface_overlays.lua")

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

T.Test3D("A ribbon beam is a strip that faces the camera", function()
	local beam = Beam.New{
		Points = 5,
		Ribbon = true,
		Radius = 0.2,
		RadiusEnd = 0,
		Material = Beam.CreateRibbonMaterial(Color(1, 0.7, 0.2), 4),
	}
	local points = Beam.NewPoints(5)
	Beam.Line(Vec3(0, 0, -5), Vec3(0, 4, -5), points)
	beam:SetRibbonPoints(points, 0.5, 1)
	local vertices = beam.vertices

	local function distance(a, b)
		local p, q = vertices[a].position, vertices[b].position
		return math.sqrt((p[0] - q[0]) ^ 2 + (p[1] - q[1]) ^ 2 + (p[2] - q[2]) ^ 2)
	end

	T(beam.point_count * 2)["=="](10)
	T(math.abs(distance(0, 1) - 0.4))["<"](1e-4)
	T(distance(8, 9))["<"](0.05)
	T(vertices[0].uv[1])["=="](0.5)
	T(math.abs(vertices[0].position[2] - -5))["<"](1e-4)
	beam:Remove()
end)

T.Test3D("A slash trail pane carries its overlay, fades at both ends and clears on release", function(draw)
	local before = surface_overlays.GetActiveCount()
	local trail = vfx.AcquireSlashTrail(Color(1, 1, 1, 1), 1, 6, "crystallize", {UVScale = {1, 1}, UVStretch = 4})

	for i = 0, 3 do
		trail:Push(Vec3(i * 0.3, 1, -4), Vec3(i * 0.3, 2, -4))
	end

	draw()
	draw()
	T(surface_overlays.GetActiveCount())["=="](before + 1)
	local vertices = trail.pane.vertices
	local count = trail.pane.point_count
	T(vertices[(count - 1) * 2].vertex_color[3])["<"](0.01)
	T(vertices[count * 2 - 2].vertex_color[3])["<"](0.01)
	T(math.abs(trail.overlay.layer.uv_scale[0] - 1))["<"](1e-4)
	T(math.abs(trail.overlay.layer.uv_scale[1] - 0.9 / 4))["<"](1e-4)
	trail:Push(Vec3(1.2, 1, -4), Vec3(1.2, 2, -4))
	trail:Push(Vec3(1.5, 1, -4), Vec3(1.5, 2, -4))
	T(vertices[0].uv[1])["<="](0)
	T(math.abs(vertices[count * 2 - 2].uv[1] - 1))["<"](1e-6)
	trail:Release()
	T(surface_overlays.GetActiveCount())["=="](before)
	trail.beam:Remove()
	trail.pane:Remove()
end)
