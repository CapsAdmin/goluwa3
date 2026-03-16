local T = import("test/environment.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local polyhedron_solver = import("goluwa/physics/pair_solvers/polyhedron.lua")

local function create_mock_body(vertices)
	local body = {
		Position = Vec3(0, 0, 0),
		Rotation = Quat(0, 0, 0, 1),
		polyhedron = {
			vertices = vertices,
			faces = {
				{indices = {1, 2}, normal = Vec3(0, 1, 0)},
			},
		},
	}

	function body:GetPosition()
		return self.Position
	end

	function body:GetRotation()
		return self.Rotation
	end

	function body:LocalToWorld(point)
		return self.Position + self.Rotation:VecMul(point)
	end

	return body
end

T.Test("Polyhedron world vertex cache reuses transformed vertex tables for unchanged transforms", function()
	local body = create_mock_body{Vec3(1, 0, 0), Vec3(0, 2, 0)}
	local first = polyhedron_solver.GetPolyhedronWorldVertices(body, body.polyhedron)
	local second = polyhedron_solver.GetPolyhedronWorldVertices(body, body.polyhedron)
	T(first == second)["=="](true)
	T(first[1].x)["=="](1)
	T(first[2].y)["=="](2)
end)

T.Test("Polyhedron world vertex cache updates cached vertices when the body transform changes", function()
	local body = create_mock_body{Vec3(1, 0, 0), Vec3(0, 0, 1)}
	local first = polyhedron_solver.GetPolyhedronWorldVertices(body, body.polyhedron)
	body.Position = Vec3(3, 0, -2)
	local second = polyhedron_solver.GetPolyhedronWorldVertices(body, body.polyhedron)
	T(first == second)["=="](true)
	T(second[1].x)["=="](4)
	T(second[1].z)["=="](-2)
	T(second[2].x)["=="](3)
	T(second[2].z)["=="](-1)
end)

T.Test("Polyhedron world face cache reuses transformed face tables for unchanged transforms", function()
	local body = create_mock_body{Vec3(1, 0, 0), Vec3(0, 2, 0)}
	local first = polyhedron_solver.GetPolyhedronWorldFace(body, body.polyhedron, 1)
	local second = polyhedron_solver.GetPolyhedronWorldFace(body, body.polyhedron, 1)
	T(first == second)["=="](true)
	T(first.points == second.points)["=="](true)
	T(first.points[1].x)["=="](1)
	T(first.points[2].y)["=="](2)
	T(first.normal.y)["=="](1)
end)

T.Test("Polyhedron world face cache updates cached face points when the body transform changes", function()
	local body = create_mock_body{Vec3(1, 0, 0), Vec3(0, 0, 1)}
	local first = polyhedron_solver.GetPolyhedronWorldFace(body, body.polyhedron, 1)
	body.Position = Vec3(3, 0, -2)
	local second = polyhedron_solver.GetPolyhedronWorldFace(body, body.polyhedron, 1)
	T(first == second)["=="](true)
	T(second.points[1].x)["=="](4)
	T(second.points[1].z)["=="](-2)
	T(second.points[2].x)["=="](3)
	T(second.points[2].z)["=="](-1)
end)