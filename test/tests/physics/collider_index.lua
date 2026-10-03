local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Quat = import("goluwa/structs/quat.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local CompoundShape = import("goluwa/physics/shapes/compound.lua")
local collider_index = import("goluwa/physics/collider_index.lua")
local PILLAR_COUNT = 40
local PILLAR_SPACING = 3

local function spawn_pillars(name, world_geometry)
	local children = {}

	for i = 0, PILLAR_COUNT - 1 do
		children[#children + 1] = {
			Shape = BoxShape.New(Vec3(1, 1, 1)),
			Position = Vec3(i * PILLAR_SPACING, 0, 0),
			Rotation = Quat(0, 0, 0, 1),
		}
	end

	local ent = Entity.New({Name = name})
	ent:AddComponent("transform")
	local body = ent:AddComponent(
		"rigid_body",
		{
			Shape = CompoundShape.New(children),
			MotionType = "static",
			Friction = 0.5,
			Restitution = 0,
			WorldGeometry = world_geometry,
		}
	)
	return ent, body
end

local function spawn_sphere(name, position)
	local ent = Entity.New({Name = name})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	local body = ent:AddComponent(
		"rigid_body",
		{
			Shape = SphereShape.New(0.3),
			Radius = 0.3,
			Friction = 0.5,
			Restitution = 0,
			CanSleep = false,
		}
	)
	return ent, body
end

T.TestPhysics("Collider index returns exactly the colliders overlapping the query box", function()
	local ent, body = spawn_pillars("collider_index_pillars")
	local query = AABB(PILLAR_SPACING * 10 - 0.2, -1, -1, PILLAR_SPACING * 12 + 0.2, 1, 1)
	local found, count = collider_index.Query(body, query, {})
	local indexed = {}

	for i = 1, count do
		indexed[found[i]] = true
	end

	local expected = 0

	for _, collider in ipairs(body:GetColliders()) do
		local bounds = collider:GetBroadphaseAABB(collider:GetPosition(), collider:GetRotation(), AABB(0, 0, 0, 0, 0, 0))
		local overlaps = bounds.max_x >= query.min_x and
			bounds.min_x <= query.max_x and
			bounds.max_y >= query.min_y and
			bounds.min_y <= query.max_y and
			bounds.max_z >= query.min_z and
			bounds.min_z <= query.max_z

		if overlaps then
			expected = expected + 1
			T(indexed[collider])["=="](true)
		end
	end

	ent:Remove()
	T(#body:GetColliders())["=="](PILLAR_COUNT)
	T(expected)["=="](3)
	T(count)["=="](expected)
end)

T.TestPhysics("Dynamic bodies rest on indexed colliders and fall between them", function()
	local ground_ent, ground = spawn_pillars("collider_index_ground")
	local on_pillar_ent = spawn_sphere("collider_index_on_pillar", Vec3(PILLAR_SPACING * 25, 3, 0))
	local in_gap_ent = spawn_sphere("collider_index_in_gap", Vec3(PILLAR_SPACING * 25 + PILLAR_SPACING * 0.5, 3, 0))
	test_helpers.Simulate(120, 1 / 60)
	local on_pillar = on_pillar_ent.transform:GetPosition():Copy()
	local in_gap = in_gap_ent.transform:GetPosition():Copy()
	local indexed = ground.ColliderIndex ~= nil
	ground_ent:Remove()
	on_pillar_ent:Remove()
	in_gap_ent:Remove()
	T(indexed)["=="](true)
	T(math.abs(on_pillar.y - 0.8))["<"](0.05)
	T(math.abs(on_pillar.x - PILLAR_SPACING * 25))["<"](0.1)
	T(in_gap.y)["<"](-5)
end)

local function spawn_brush_pillars(name)
	local ent = Entity.New({Name = name})
	ent:AddComponent("transform")
	local shapes = {}

	for i = 0, PILLAR_COUNT - 1 do
		local min_x = i * PILLAR_SPACING - 0.5
		local max_x = i * PILLAR_SPACING + 0.5
		shapes[#shapes + 1] = {
			Model = {
				Owner = ent,
				Visible = true,
				WorldSpaceVertices = true,
				AABB = AABB(min_x, -0.5, -0.5, max_x, 0.5, 0.5),
				Primitives = {
					{
						brush_planes = {
							{normal = Vec3(1, 0, 0), dist = max_x},
							{normal = Vec3(-1, 0, 0), dist = -min_x},
							{normal = Vec3(0, 1, 0), dist = 0.5},
							{normal = Vec3(0, -1, 0), dist = 0.5},
							{normal = Vec3(0, 0, 1), dist = 0.5},
							{normal = Vec3(0, 0, -1), dist = 0.5},
						},
						aabb = AABB(min_x, -0.5, -0.5, max_x, 0.5, 0.5),
					},
				},
			},
		}
	end

	local body = ent:AddComponent(
		"rigid_body",
		{Shapes = shapes, MotionType = "static", GravityScale = 0, WorldGeometry = true}
	)
	return ent, body
end

T.TestPhysics("Sweeps find indexed colliders", function()
	local ground_ent, ground = spawn_brush_pillars("collider_index_sweep")
	local hit = physics.Sweep(
		Vec3(PILLAR_SPACING * 30, 4, 0),
		Vec3(0, -8, 0),
		0.2,
		nil,
		nil,
		{UseRenderMeshes = false}
	)
	local miss = physics.Sweep(
		Vec3(PILLAR_SPACING * 30 + PILLAR_SPACING * 0.5, 4, 0),
		Vec3(0, -8, 0),
		0.2,
		nil,
		nil,
		{UseRenderMeshes = false}
	)
	local indexed = ground.ColliderIndex ~= nil
	ground_ent:Remove()
	T(#ground:GetColliders())["=="](PILLAR_COUNT)
	T(indexed)["=="](true)
	T(hit ~= nil)["=="](true)
	T(math.abs(hit.position.y - 0.5))["<"](0.05)
	T(miss == nil)["=="](true)
end)
