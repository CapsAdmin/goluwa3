local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local RigidBodyComponent = import("goluwa/physics/rigid_body.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local sphere_shape = SphereShape.New
local create_flat_ground = test_helpers.CreateFlatGround

T.TestPhysics("Rigid body smoke test lands on ground mesh", function()
	local ground = create_flat_ground("rigid_body_ground", 4)
	local body_ent = Entity.New({Name = "rigid_body"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(0, 3, 0))
	local body = body_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	test_helpers.Simulate(240)
	local position = body_ent.transform:GetPosition()
	T(body:GetGrounded())["=="](true)
	T(position.y)[">="](0.45)
	T(position.y)["<="](0.7)
	T(body:GetGroundNormal().y)[">"](0.9)
	body_ent:Remove()
	ground:Remove()
end)

T.TestPhysics("Rigid body ground damping does not slow falling", function()
	local ground = create_flat_ground("rigid_body_damping_ground", 4)
	local body_ent = Entity.New({Name = "rigid_body_ground_damping"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(0, 3, 0))
	local body = body_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			LinearDamping = 6,
			AngularDamping = 2,
		}
	)
	test_helpers.Simulate(120)
	local position = body_ent.transform:GetPosition()
	T(body:GetGrounded())["=="](true)
	T(position.y)[">="](0.45)
	T(position.y)["<="](0.7)
	body_ent:Remove()
	ground:Remove()
end)

T.TestPhysics("Rigid sphere can move along uneven ground", function()
	local ground = Entity.New({Name = "rigid_body_slope_ground"})
	ground:AddComponent("transform")
	local poly = Polygon3D.New()
	test_helpers.AddTriangle(poly, Vec3(-4, 2, -4), Vec3(-4, 2, 4), Vec3(4, 0, -4))
	test_helpers.AddTriangle(poly, Vec3(4, 0, -4), Vec3(-4, 2, 4), Vec3(4, 0, 4))
	poly:BuildBoundingBox()
	test_helpers.AttachWorldGeometryBody(ground, poly)
	local body_ent = Entity.New({Name = "rigid_body_slope"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(-1.5, 3, 0))
	local body = body_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	test_helpers.Simulate(240)
	local position = body_ent.transform:GetPosition()
	T(body:GetGrounded())["=="](true)
	T(position.x)[">"](0.5)
	T(position.y)[">="](0.8)
	body_ent:Remove()
	ground:Remove()
end)

T.TestPhysics("Fast rigid sphere does not tunnel through triangle world floor", function()
	local ground = create_flat_ground("rigid_fast_sphere_ground", 6)
	local body_ent = Entity.New({Name = "rigid_fast_sphere"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(0, 4, 0))
	local body = body_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	body:SetVelocity(Vec3(0, -60, 0))
	test_helpers.Simulate(12)
	local position = body_ent.transform:GetPosition()
	T(position.y)[">="](0.4)
	T(body:GetGrounded() or body:GetVelocity().y > -5)["=="](true)
	body_ent:Remove()
	ground:Remove()
end)

T.TestPhysics("Rigid spheres separate without exploding", function()
	local ground = create_flat_ground("rigid_pair_ground")
	local sphere_a = Entity.New({Name = "rigid_pair_a"})
	sphere_a:AddComponent("transform")
	sphere_a.transform:SetPosition(Vec3(-0.45, 2.5, 0))
	local body_a = sphere_a:AddComponent("rigid_body", {
		Shape = sphere_shape(0.5),
		Radius = 0.5,
	})
	local sphere_b = Entity.New({Name = "rigid_pair_b"})
	sphere_b:AddComponent("transform")
	sphere_b.transform:SetPosition(Vec3(0.45, 2.5, 0))
	local body_b = sphere_b:AddComponent("rigid_body", {
		Shape = sphere_shape(0.5),
		Radius = 0.5,
	})
	test_helpers.Simulate(180)
	local pos_a = sphere_a.transform:GetPosition()
	local pos_b = sphere_b.transform:GetPosition()
	local separation = (pos_b - pos_a):GetLength()
	T(body_a:GetGrounded())["=="](true)
	T(body_b:GetGrounded())["=="](true)
	T(separation)[">="](0.95)
	T(math.abs(pos_a.x))["<"](3)
	T(math.abs(pos_b.x))["<"](3)
	sphere_a:Remove()
	sphere_b:Remove()
	ground:Remove()
end)

T.Test("Rigid body removal prunes Instances immediately", function()
	local entity = Entity.New({Name = "rigid_body_instance_cleanup"})
	entity:AddComponent("transform")
	local body = entity:AddComponent("rigid_body", {
		Shape = sphere_shape(0.5),
		Radius = 0.5,
	})
	local instances = RigidBodyComponent.Instances
	local before = #instances
	entity:Remove()
	T(#instances)["=="](before - 1)

	for i = 1, #instances do
		T(instances[i])["~="](body)
	end
end)

T.TestPhysics("Locked rotation keeps a body upright under off-center impulses and contacts", function()
	local ground = create_flat_ground("rigid_body_lock_ground", 6)
	local body_ent = Entity.New({Name = "rigid_body_lock"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(0, 1.5, 0))
	local body = body_ent:AddComponent(
		"rigid_body",
		{
			Shape = import("goluwa/physics/shapes/capsule.lua").New(0.3, 1.2),
			Radius = 0.3,
			Height = 1.2,
			LockRotation = true,
			LinearDamping = 0,
			AngularDamping = 0,
			Friction = 0.8,
		}
	)

	for step = 1, 120 do
		if step % 10 == 0 then
			body:ApplyImpulse(Vec3(3, 0, 1), body:GetPosition() + Vec3(0, 0.5, 0))
		end

		test_helpers.Simulate(1)
	end

	local rotation = body_ent.transform:GetRotation()
	body_ent:Remove()
	ground:Remove()
	T(body:GetAngularVelocity():GetLength())["=="](0)
	T(math.abs(rotation.x) + math.abs(rotation.y) + math.abs(rotation.z))["<"](0.0001)
end)

T.TestPhysics("Rigid body Inertia replaces the tensor built from its shapes", function()
	local ent = Entity.New({Name = "inertia_override"})
	ent:AddComponent("transform")
	local body = ent:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(1, 1, 1)),
			Size = Vec3(1, 1, 1),
			Mass = 4,
			AutomaticMass = false,
		}
	)
	local computed = body.InertiaTensor.m00
	body:SetInertia(Vec3(2, 3, 5))
	T(body.InertiaTensor.m00)["=="](2)
	T(body.InertiaTensor.m11)["=="](3)
	T(body.InertiaTensor.m22)["=="](5)
	T(body.InverseInertiaTensor.m22)["~"](0.2)
	body:SetInertia(nil)
	T(body.InertiaTensor.m00)["~"](computed)
	ent:Remove()
end)
