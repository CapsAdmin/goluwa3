local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local MeshShape = import("goluwa/physics/shapes/mesh.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")

local function simulate_physics(steps, dt)
	dt = dt or (1 / 120)

	for _ = 1, steps do
		physics.Update(dt)
	end
end

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
	ent:AddComponent("rigid_body", {
		Shape = MeshShape.New{Model = model},
		MotionType = "static",
		WorldGeometry = true,
	})
	return ent
end

T.Test("Dynamic bodies resolve against world geometry rigid bodies without world bridge", function()
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
	simulate_physics(6, 1 / 120)
	local position = body:GetPosition()
	body_ent:Remove()
	world_ent:Remove()
	T(position.y)[">="](0.09)
end)

T.Test("Solver swept body contact path ignores invalid bodies", function()
	T(physics.solver:SolveBodyContacts(nil, 1 / 60))["=="](false)
end)
