local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local OPTIONS = {IgnoreRigidBodies = false, IgnoreKinematicBodies = false}
local DIAGONAL = Vec3(1, 0, 1):GetNormalized()

local function create_box(position)
	return Entity.New{
		transform = {Position = position},
		rigid_body = {Shape = BoxShape.New(Vec3(1, 1, 1)), MotionType = "static"},
	}
end

local function create_scene()
	local entities = {}

	for k = 1, 40 do
		entities[#entities + 1] = create_box(Vec3(10 * k, 0, 10 * k))
	end

	for i = 0, 199 do
		entities[#entities + 1] = create_box(Vec3(7 * (i % 20), 0, 100 + 7 * math.floor(i / 20)))
	end

	entities[#entities + 1] = create_box(Vec3(10, 0, 2))
	return entities
end

T.TestPhysics("ray casts return the nearest of many bodies, before and after the broadphase tracks them", function()
	local entities = create_scene()
	local origin = Vec3(0, 0, 0.2)

	for pass = 1, 2 do
		local hit = physics.RayCast(origin, DIAGONAL, 1000, nil, nil, OPTIONS)
		T(hit ~= nil)["=="](true)
		T(hit.entity == entities[1])["=="](true)
		T(hit.distance)["~"](9.5 * math.sqrt(2), 1e-3)
		local second = physics.RayCast(origin, DIAGONAL, 1000, entities[1], nil, OPTIONS)
		T(second.entity == entities[2])["=="](true)
		T(second.distance)["~"](19.5 * math.sqrt(2), 1e-3)
		T(physics.RayCast(origin, DIAGONAL, 13, nil, nil, OPTIONS) == nil)["=="](true)
		local axis = physics.RayCast(Vec3(-5, 0, 100), Vec3(1, 0, 0), 500, nil, nil, OPTIONS)
		T(axis.distance)["~"](4.5, 1e-3)
		physics.Update(1 / 60)
	end

	for _, entity in ipairs(entities) do
		entity:Remove()
	end
end)

T.TestPhysics("ray casts miss bodies inside the ray bounds but off the ray", function()
	local beside = create_box(Vec3(10, 0, 2))
	T(physics.RayCast(Vec3(0, 0, 0), DIAGONAL, 30, nil, nil, OPTIONS) == nil)["=="](true)
	T(physics.RayCast(Vec3(0, 0, 2), Vec3(1, 0, 0), 30, nil, nil, OPTIONS).entity == beside)["=="](true)
	beside:Remove()
end)

T.TestPhysics("long ray casts reach far bodies", function()
	local far = create_box(Vec3(5000, 0, 0))
	local hit = physics.RayCast(Vec3(0, 0, 0), Vec3(1, 0, 0), 100000, nil, nil, OPTIONS)
	T(hit ~= nil)["=="](true)
	T(hit.entity == far)["=="](true)
	T(hit.distance)["~"](4999.5, 1e-2)
	far:Remove()
end)

T.TestPhysics("ray casts only trace the colliders near the ray", function()
	local traced = 0
	local entities = {}

	for i = 0, 299 do
		local shape = BoxShape.New(Vec3(1, 1, 1))
		local trace_against_body = shape.TraceAgainstBody

		function shape:TraceAgainstBody(...)
			traced = traced + 1
			return trace_against_body(self, ...)
		end

		entities[i + 1] = Entity.New{
			transform = {Position = Vec3(10 * (i % 30), 0, 10 * math.floor(i / 30))},
			rigid_body = {Shape = shape, MotionType = "static"},
		}
	end

	local hit = physics.RayCast(Vec3(-5, 0, 0), Vec3(1, 0, 0), 400, nil, nil, OPTIONS)
	T(hit.entity == entities[1])["=="](true)
	T(traced)["<"](40)

	for _, entity in ipairs(entities) do
		entity:Remove()
	end
end)

T.TestPhysics("ray casts report where they leave solids and which side of a mesh they hit", function()
	local SphereShape = import("goluwa/physics/shapes/sphere.lua")
	local MeshShape = import("goluwa/physics/shapes/mesh.lua")
	local box = create_box(Vec3(0, 0, 10))
	local through = physics.RayCast(Vec3(0, 0, 5), Vec3(0, 0, 1), 100, nil, nil, OPTIONS)
	T(through.distance)["~"](4.5, 1e-4)
	T(through.exit_distance)["~"](5.5, 1e-4)
	box:Remove()
	local ball = Entity.New{
		transform = {Position = Vec3(0, 0, 20)},
		rigid_body = {Shape = SphereShape.New(2), MotionType = "static"},
	}
	physics.Update(1 / 60)
	local sphere_hit = physics.RayCast(Vec3(0, 0, 10), Vec3(0, 0, 1), 100, nil, nil, OPTIONS)
	T(sphere_hit.distance)["~"](8, 1e-4)
	T(sphere_hit.exit_distance)["~"](12, 1e-4)
	ball:Remove()
	local brush = Entity.New{transform = {Position = Vec3(30, 0, 0)}}
	brush:AddComponent(
		"rigid_body",
		{
			Shape = MeshShape.New{
				Model = {
					Primitives = {
						{
							brush_planes = {
								{normal = Vec3(1, 0, 0), dist = 1},
								{normal = Vec3(-1, 0, 0), dist = 1},
								{normal = Vec3(0, 1, 0), dist = 1},
								{normal = Vec3(0, -1, 0), dist = 1},
								{normal = Vec3(0, 0, 1), dist = 1},
								{normal = Vec3(0, 0, -1), dist = 1},
							},
						},
					},
				},
			},
			MotionType = "static",
		}
	)
	physics.Update(1 / 60)
	local outside = physics.RayCast(Vec3(25, 0, 0), Vec3(1, 0, 0), 100, nil, nil, OPTIONS)
	T(outside.distance)["~"](4, 1e-4)
	T(outside.front_face)["=="](true)
	local inside = physics.RayCast(Vec3(30, 0, 0), Vec3(1, 0, 0), 100, nil, nil, OPTIONS)
	T(inside.distance)["~"](1, 1e-4)
	T(inside.front_face)["=="](false)
	T(inside.normal.x)["<"](-0.999)
	brush:Remove()
end)

T.TestPhysics("a ray against a candidate list hits what a ray collecting its own candidates hits", function()
	local entities = create_scene()
	local AABB = import("goluwa/structs/aabb.lua")
	local candidates = physics.CollectRayCandidates(AABB(-5, -5, -5, 450, 5, 450), nil, nil, OPTIONS, {})
	T(#candidates >= #entities)["=="](true)
	local listed = {
		IgnoreRigidBodies = false,
		IgnoreKinematicBodies = false,
		Candidates = candidates,
	}
	local origin = Vec3(0, 0, 0.2)
	local own = physics.RayCast(origin, DIAGONAL, 1000, nil, nil, OPTIONS)
	local from_list = physics.RayCast(origin, DIAGONAL, 1000, nil, nil, listed)
	T(from_list.entity == own.entity)["=="](true)
	T(from_list.distance)["~"](own.distance, 1e-6)
	T(physics.RayCast(origin, DIAGONAL, 13, nil, nil, listed) == nil)["=="](true)
	local axis = physics.RayCast(Vec3(-5, 0, 100), Vec3(1, 0, 0), 500, nil, nil, listed)
	T(axis.distance)["~"](4.5, 1e-3)

	for _, entity in ipairs(entities) do
		entity:Remove()
	end
end)
