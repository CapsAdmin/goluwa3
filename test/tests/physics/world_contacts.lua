local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local world_mesh_contacts = import("goluwa/physics/world_mesh_contacts.lua")
local raycast = import("goluwa/physics/raycast.lua")
local world_contacts = import("goluwa/physics/world_contacts.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local AABB = import("goluwa/structs/aabb.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")

local function create_mock_body(data)
	return test_helpers.CreateTestRigidBody(data)
end

local function create_brush_world_source(mins, maxs)
	local ent = Entity.New({Name = "world_contacts_brush_source"})
	ent:AddComponent("transform")
	local source = raycast.CreateModelSource{
		{
			Owner = ent,
			Visible = true,
			WorldSpaceVertices = true,
			AABB = AABB(mins.x, mins.y, mins.z, maxs.x, maxs.y, maxs.z),
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
					aabb = AABB(mins.x, mins.y, mins.z, maxs.x, maxs.y, maxs.z),
				},
			},
		},
	}
	return ent, source
end

T.Test("World contacts resolve brush primitives through rigid world bridge", function()
	local old_source = physics.GetWorldTraceSource
	local source_ent, source = create_brush_world_source(Vec3(-1, -1, -1), Vec3(1, 0, 1))
	local body_ent = Entity.New({Name = "world_contacts_brush_body"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(0, 0.05, 0))
	local body = body_ent:AddComponent("rigid_body", {
		Shape = SphereShape.New(0.1),
		Radius = 0.1,
		LinearDamping = 0,
		AngularDamping = 0,
	})
	physics.GetWorldTraceSource = function()
		return source
	end
	physics.Update(1 / 60)
	physics.GetWorldTraceSource = old_source
	local position = body:GetPosition()
	body_ent:Remove()
	source_ent:Remove()
	T(position.y)[">="](0.09)
	T(body:GetGrounded())["=="](true)
end)

T.Test("World contacts use swept rigid world bridge as fallback only", function()
	local old_resolve = world_mesh_contacts.ResolveBodyAgainstWorldPrimitives
	local old_resolve_swept = world_mesh_contacts.ResolveSweptBodyAgainstWorldPrimitives
	local body = create_mock_body{
		Position = Vec3(0, 0.05, 0),
		PreviousPosition = Vec3(0, 0.05, 0),
	}
	local overlap_calls = 0
	local sweep_calls = 0

	world_mesh_contacts.ResolveBodyAgainstWorldPrimitives = function()
		overlap_calls = overlap_calls + 1
		return false
	end

	world_mesh_contacts.ResolveSweptBodyAgainstWorldPrimitives = function()
		sweep_calls = sweep_calls + 1
		return true
	end

	world_contacts.SolveBodyContacts(body, 1 / 60)
	world_mesh_contacts.ResolveBodyAgainstWorldPrimitives = old_resolve
	world_mesh_contacts.ResolveSweptBodyAgainstWorldPrimitives = old_resolve_swept
	T(overlap_calls)["=="](0)
	T(sweep_calls)["=="](1)
end)
