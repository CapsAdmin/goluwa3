local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

local function build_triangle_hit(a, b, c, hit_position, hit_normal)
	return {
		primitive = {
			polygon3d = {
				Vertices = {
					{pos = a},
					{pos = b},
					{pos = c},
				},
			},
		},
		triangle_index = 0,
		position = hit_position,
		normal = hit_normal,
	}
end

local function build_indexed_triangle_hit(vertices, indices, triangle_index, hit_position, hit_normal)
	local poly_vertices = {}

	for i, vertex in ipairs(vertices) do
		poly_vertices[i] = {pos = vertex}
	end

	return {
		primitive = {
			polygon3d = {
				Vertices = poly_vertices,
				indices = indices,
			},
		},
		triangle_index = triangle_index,
		position = hit_position,
		normal = hit_normal,
	}
end

local function build_model_triangle_hit(primitives, primitive_index, triangle_index, hit_position, hit_normal)
	local model_primitives = {}

	for i, primitive in ipairs(primitives) do
		local poly_vertices = {}

		for vertex_index, vertex in ipairs(primitive.vertices) do
			poly_vertices[vertex_index] = {pos = vertex}
		end

		model_primitives[i] = {
			polygon3d = {
				Vertices = poly_vertices,
				indices = primitive.indices,
			},
		}
	end

	local model = {
		Primitives = model_primitives,
	}
	return {
		model = model,
		primitive = model_primitives[primitive_index],
		triangle_index = triangle_index,
		position = hit_position,
		normal = hit_normal,
	}
end

T.Test("Triangle hit surface contact keeps interior face contacts stable", function()
	local hit = build_triangle_hit(
		Vec3(-1, 0, -1),
		Vec3(1, 0, -1),
		Vec3(-1, 0, 1),
		Vec3(-0.25, 0, -0.25),
		Vec3(0, 1, 0)
	)
	local reference_point = Vec3(-0.25, 0.6, -0.25)
	local contact = physics.GetHitSurfaceContact(hit, reference_point)
	T(contact ~= nil)["=="](true)
	T(math.abs(contact.position.x + 0.25))["<"](0.0001)
	T(math.abs(contact.position.y))["<"](0.0001)
	T(math.abs(contact.position.z + 0.25))["<"](0.0001)
	T(contact.normal.y)[">"](0.999)
	T(math.abs(contact.normal.x))["<"](0.0001)
	T(math.abs(contact.normal.z))["<"](0.0001)
end)

T.Test("Triangle hit surface contact resolves edge features from closest point", function()
	local hit = build_triangle_hit(
		Vec3(0, 0, 0),
		Vec3(2, 0, 0),
		Vec3(0, 0, 2),
		Vec3(1.2, 0, 0.8),
		Vec3(0, 1, 0)
	)
	local reference_point = Vec3(1.6, 0.3, 1.6)
	local contact = physics.GetHitSurfaceContact(hit, reference_point)
	T(contact ~= nil)["=="](true)
	T(math.abs(contact.position.x - 1))["<"](0.0001)
	T(math.abs(contact.position.y))["<"](0.0001)
	T(math.abs(contact.position.z - 1))["<"](0.0001)
	T(contact.normal.x)[">"](0.66)
	T(contact.normal.y)[">"](0.33)
	T(contact.normal.z)[">"](0.66)
end)

T.Test("Triangle hit surface contact crosses coplanar mesh seams to the nearest triangle", function()
	local hit = build_indexed_triangle_hit(
		{
			Vec3(0, 0, 0),
			Vec3(1, 0, 0),
			Vec3(0, 0, 1),
			Vec3(1, 0, 1),
		},
		{0, 1, 2, 1, 3, 2},
		0,
		Vec3(0.5, 0, 0.5),
		Vec3(0, 1, 0)
	)
	local reference_point = Vec3(0.8, 0.4, 0.8)
	local contact = physics.GetHitSurfaceContact(hit, reference_point)
	T(contact ~= nil)["=="](true)
	T(math.abs(contact.position.x - 0.8))["<"](0.0001)
	T(math.abs(contact.position.y))["<"](0.0001)
	T(math.abs(contact.position.z - 0.8))["<"](0.0001)
	T(contact.normal.y)[">"](0.999)
	T(math.abs(contact.normal.x))["<"](0.0001)
	T(math.abs(contact.normal.z))["<"](0.0001)
end)

T.Test("Triangle hit surface contact crosses seams between separate model primitives", function()
	local hit = build_model_triangle_hit(
		{
			{
				vertices = {
					Vec3(0, 0, 0),
					Vec3(1, 0, 0),
					Vec3(0, 0, 1),
				},
			},
			{
				vertices = {
					Vec3(1, 0, 0),
					Vec3(1, 0, 1),
					Vec3(0, 0, 1),
				},
			},
		},
		1,
		0,
		Vec3(0.5, 0, 0.5),
		Vec3(0, 1, 0)
	)
	local reference_point = Vec3(0.8, 0.4, 0.8)
	local contact = physics.GetHitSurfaceContact(hit, reference_point)
	T(contact ~= nil)["=="](true)
	T(math.abs(contact.position.x - 0.8))["<"](0.0001)
	T(math.abs(contact.position.y))["<"](0.0001)
	T(math.abs(contact.position.z - 0.8))["<"](0.0001)
	T(contact.normal.y)[">"](0.999)
	T(math.abs(contact.normal.x))["<"](0.0001)
	T(math.abs(contact.normal.z))["<"](0.0001)
end)
