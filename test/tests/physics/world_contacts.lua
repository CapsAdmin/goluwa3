local T = import("test/environment.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local MeshShape = import("goluwa/physics/shapes/mesh.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")

local function create_world_brush_body(mins, maxs)
	local ent = Entity.New({Name = "world_contacts_brush_body"})
	ent:AddComponent("transform")
	local model = {
		Owner = ent,
		Visible = true,
		WorldSpaceVertices = true,
		Primitives = {
			{
				brush_planes = {
					{normal = Vec3(1, 0, 0), dist = maxs.x},
					{normal = Vec3(-1, 0, 0), dist = -mins.x},
					{normal = Vec3(0, 1, 0), dist = maxs.y},
					{normal = Vec3(0, -1, 0), dist = -mins.y},
					{normal = Vec3(0, 0, 1), dist = maxs.z},
					{normal = Vec3(0, 0, -1), dist = -mins.z},
				},
			},
		},
	}
	ent:AddComponent(
		"rigid_body",
		{
			Shape = MeshShape.New{Model = model},
			MotionType = "static",
			WorldGeometry = true,
		}
	)
	return ent
end

T.TestPhysics("Dynamic bodies resolve against world geometry rigid bodies without world bridge", function()
	local world_ent = create_world_brush_body(Vec3(-1, -1, -1), Vec3(1, 0, 1))
	local body_ent = Entity.New({Name = "world_contacts_dynamic_body"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(0, 0.05, 0))
	local body = body_ent:AddComponent(
		"rigid_body",
		{
			Shape = SphereShape.New(0.1),
			Radius = 0.1,
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	test_helpers.Simulate(6, 1 / 120)
	local position = body:GetPosition()
	body_ent:Remove()
	world_ent:Remove()
	T(position.y)[">="](0.09)
end)

T.TestPhysics("Solver swept body contact path ignores invalid bodies", function()
	local physics = import("goluwa/physics.lua")
	T(physics.instance.solver:SolveBodyContacts(nil, 1 / 60))["=="](false)
end)
