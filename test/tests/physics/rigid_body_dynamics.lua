local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local sphere_shape = SphereShape.New
local box_shape = BoxShape.New

local function simulate_physics(steps, dt)
	return test_helpers.SimulatePhysics(physics, steps, dt)
end

T.Test3D("Rigid body collision response supports friction and restitution", function()
	local platform_ent = Entity.New({Name = "rigid_material_platform"})
	platform_ent:AddComponent("transform")
	platform_ent.transform:SetPosition(Vec3(0, 1, 0))
	platform_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(8, 1, 8)),
			Size = Vec3(8, 1, 8),
			MotionType = "static",
			Friction = 1,
			Restitution = 0.8,
		}
	)
	local sphere_ent = Entity.New({Name = "rigid_material_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0, 4, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
			Friction = 1,
			Restitution = 0.8,
		}
	)
	sphere:SetVelocity(Vec3(8, -18, 0))
	simulate_physics(24)
	local velocity = sphere:GetVelocity()
	local angular = sphere:GetAngularVelocity()
	T(velocity.y)[">"](6)
	T(math.abs(velocity.x))[">"](4)
	T(math.abs(velocity.x))["<"](7)
	T(math.abs(angular.z))[">"](6)
	platform_ent:Remove()
	sphere_ent:Remove()
end)

T.Test3D("Rigid bodies can sleep and wake on contact", function()
	local ground_ent = Entity.New({Name = "rigid_sleep_ground"})
	ground_ent:AddComponent("transform")
	ground_ent.transform:SetPosition(Vec3(0, 1, 0))
	ground_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(8, 1, 8)),
			Size = Vec3(8, 1, 8),
			MotionType = "static",
			Friction = 1,
		}
	)
	local sphere_ent = Entity.New({Name = "rigid_sleep_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0, 4, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			LinearDamping = 12,
			AngularDamping = 12,
			Friction = 1,
			SleepDelay = 0.5,
			SleepLinearThreshold = 0.025,
			SleepAngularThreshold = 0.025,
		}
	)
	simulate_physics(240)
	local settled_x = sphere_ent.transform:GetPosition().x
	T(sphere:GetAwake())["=="](false)
	T(sphere:GetVelocity():GetLength())["<"](0.01)
	sphere:SetVelocity(Vec3(4, 0, 0))
	simulate_physics(1, 1 / 60)
	local moved_x = sphere_ent.transform:GetPosition().x
	T(sphere:GetAwake())["=="](true)
	T(moved_x)[">"](settled_x + 0.01)
	ground_ent:Remove()
	sphere_ent:Remove()
end)

T.Test3D("Rigid boxes respect sleep delay before regular sleep", function()
	local box_ent = Entity.New({Name = "rigid_sleep_delay_box"})
	box_ent:AddComponent("transform")
	box_ent.transform:SetPosition(Vec3(0, 1.5, 0))
	local box = box_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(1, 1, 1)),
			Size = Vec3(1, 1, 1),
			LinearDamping = 0,
			AngularDamping = 0,
			Friction = 1,
			SleepDelay = 0.5,
			SleepLinearThreshold = 0.15,
			SleepAngularThreshold = 0.15,
		}
	)
	box:SetVelocity(Vec3(0.01, 0, 0))
	box:SetAngularVelocity(Vec3(0.02, 0, 0))

	for _ = 1, 20 do
		box:UpdateSleepState(1 / 60)
	end

	T(box:GetAwake())["=="](true)
	T(box.SleepTimer)[">"](0.3)
	T(box.SleepTimer)["<"](box:GetSleepDelay())

	for _ = 1, 20 do
		box:UpdateSleepState(1 / 60)
	end

	T(box:GetAwake())["=="](false)
	box_ent:Remove()
end)

T.Test3D("Rigid boxes do not force grounded sleep on awake dynamic supports", function()
	local support_ent = Entity.New({Name = "rigid_sleep_support_box"})
	support_ent:AddComponent("transform")
	support_ent.transform:SetPosition(Vec3(0, 0.5, 0))
	local support = support_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(2, 1, 2)),
			Size = Vec3(2, 1, 2),
			Mass = 6,
			AutomaticMass = false,
			LinearDamping = 0,
			AngularDamping = 0,
			Friction = 1,
		}
	)
	local top_ent = Entity.New({Name = "rigid_sleep_top_box"})
	top_ent:AddComponent("transform")
	top_ent.transform:SetPosition(Vec3(0, 1.5, 0))
	local top = top_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(1, 1, 1)),
			Size = Vec3(1, 1, 1),
			LinearDamping = 0,
			AngularDamping = 0,
			Friction = 1,
			SleepDelay = 0.5,
			SleepLinearThreshold = 0.15,
			SleepAngularThreshold = 0.15,
		}
	)
	top:SetGrounded(true)
	top:SetGroundNormal(Vec3(0, 1, 0))
	top:SetGroundBody(support)
	top:ResetGroundSupport()
	top:AccumulateGroundSupportContact(Vec3(0, 1, 0), Vec3(-0.45, 1, -0.45))
	top:AccumulateGroundSupportContact(Vec3(0, 1, 0), Vec3(0.45, 1, -0.45))
	top:AccumulateGroundSupportContact(Vec3(0, 1, 0), Vec3(-0.45, 1, 0.45))
	top:AccumulateGroundSupportContact(Vec3(0, 1, 0), Vec3(0.45, 1, 0.45))
	top:SetVelocity(Vec3(0.01, 0, 0))
	top:SetAngularVelocity(Vec3(0.02, 0, 0))
	support:SetVelocity(Vec3(0.35, 0, 0))
	local ready, force_sleep = top:IsReadyToSleep()
	T(ready)["=="](true)
	T(force_sleep)["=="](false)
	support:SetVelocity(Vec3(0, 0, 0))
	ready, force_sleep = top:IsReadyToSleep()
	T(ready)["=="](true)
	T(force_sleep)["=="](true)
	top_ent:Remove()
	support_ent:Remove()
end)

T.Test3D("Sleeping bodies wake when their sleeping dynamic support drops", function()
	local support_ent = Entity.New({Name = "rigid_drop_support_box"})
	support_ent:AddComponent("transform")
	support_ent.transform:SetPosition(Vec3(0, 0.5, 0))
	local support = support_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(2, 1, 2)),
			Size = Vec3(2, 1, 2),
			Mass = 6,
			AutomaticMass = false,
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			AirLinearDamping = 0,
			AirAngularDamping = 0,
			Friction = 1,
		}
	)
	local top_ent = Entity.New({Name = "rigid_drop_top_box"})
	top_ent:AddComponent("transform")
	top_ent.transform:SetPosition(Vec3(0, 1.5, 0))
	local top = top_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(1, 1, 1)),
			Size = Vec3(1, 1, 1),
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			AirLinearDamping = 0,
			AirAngularDamping = 0,
			Friction = 1,
		}
	)
	top:SetGrounded(true)
	top:SetGroundNormal(Vec3(0, 1, 0))
	top:SetGroundBody(support)
	top:ResetGroundSupport()
	top:AccumulateGroundSupportContact(Vec3(0, 1, 0), Vec3(-0.45, 1, -0.45))
	top:AccumulateGroundSupportContact(Vec3(0, 1, 0), Vec3(0.45, 1, -0.45))
	top:AccumulateGroundSupportContact(Vec3(0, 1, 0), Vec3(-0.45, 1, 0.45))
	top:AccumulateGroundSupportContact(Vec3(0, 1, 0), Vec3(0.45, 1, 0.45))
	top:Sleep()
	support:Sleep()
	support:SetVelocity(Vec3(0, -2, 0))
	simulate_physics(1, 1 / 60)
	T(support:GetAwake())["=="](true)
	T(top:GetAwake())["=="](true)
	top_ent:Remove()
	support_ent:Remove()
end)

T.Test3D("Rigid body force and impulse API", function()
	local sphere_ent = Entity.New({Name = "rigid_force_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0, 0, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			AutomaticMass = false,
			Mass = 2,
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			AirLinearDamping = 0,
			AirAngularDamping = 0,
		}
	)
	sphere:ApplyImpulse(Vec3(4, 0, 0))
	T(sphere:GetVelocity().x)["=="](2)

	for _ = 1, 30 do
		sphere:ApplyForce(Vec3(0, 12, 0))
		physics.Update(1 / 60)
	end

	local sphere_position = sphere_ent.transform:GetPosition()
	T(sphere:GetVelocity().y)[">"](2.9)
	T(sphere_position.x)[">"](0.9)
	T(sphere_position.y)[">"](0.7)
	local box_ent = Entity.New({Name = "rigid_force_box"})
	box_ent:AddComponent("transform")
	box_ent.transform:SetPosition(Vec3(0, 0, 0))
	local box = box_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(2, 1, 1)),
			Size = Vec3(2, 1, 1),
			AutomaticMass = false,
			Mass = 1,
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			AirLinearDamping = 0,
			AirAngularDamping = 0,
		}
	)
	box:ApplyAngularImpulse(Vec3(0, 0, 2))

	for _ = 1, 30 do
		box:ApplyForce(Vec3(0, 0, 12), box:GetPosition() + Vec3(1, 0, 0))
		physics.Update(1 / 60)
	end

	local box_angular = box:GetAngularVelocity()
	T(math.abs(box_angular.z))[">"](1.5)
	T(math.abs(box_angular.y))[">"](2.5)
	sphere_ent:Remove()
	box_ent:Remove()
end)

T.Test3D("Rigid body collisions apply angular impulse from off-center impacts", function()
	local sphere_ent = Entity.New({Name = "rigid_angular_hit_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(-3, 1.45, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
			Restitution = 0,
		}
	)
	local box_ent = Entity.New({Name = "rigid_angular_hit_box"})
	box_ent:AddComponent("transform")
	box_ent.transform:SetPosition(Vec3(0, 1, 0))
	local box = box_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(1.5, 1.5, 1.5)),
			Size = Vec3(1.5, 1.5, 1.5),
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
			Restitution = 0,
		}
	)
	sphere:SetVelocity(Vec3(40, 0, 0))
	simulate_physics(18, 1 / 120)
	local angular = box:GetAngularVelocity()
	local linear = box:GetVelocity()
	local sphere_position = sphere_ent.transform:GetPosition()
	local box_position = box_ent.transform:GetPosition()
	sphere_ent:Remove()
	box_ent:Remove()
	T(linear.x)[">"](2)
	T(math.abs(angular.z))[">"](1.2)
	T(math.abs(angular.x))["<"](0.75)
	T(math.abs(box_position.y - 1))["<"](0.5)
	T(sphere_position.x)["<"](box_position.x)
end)

T.Test3D("Sphere dropped above the scene box edge does not snag on the platform", function()
	local box_center = Vec3(1.4, 1.85, 0)
	local box_size = Vec3(6, 0.7, 4.5)
	local sphere_radius = 0.28
	local sphere_spawn = Vec3(4.6, 100, 0)
	local bottom_y = box_center.y - box_size.y * 0.5
	local platform_ent = Entity.New({Name = "rigid_scene_edge_platform"})
	platform_ent:AddComponent("transform")
	platform_ent.transform:SetPosition(box_center)
	platform_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(box_size),
			Size = box_size,
			MotionType = "static",
			Friction = 0.7,
			Restitution = 0,
		}
	)
	local sphere_ent = Entity.New({Name = "rigid_scene_edge_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(sphere_spawn)
	sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(sphere_radius),
			Radius = sphere_radius,
			LinearDamping = 0.08,
			AngularDamping = 0.35,
			Friction = 0.2,
			Restitution = 0.25,
		}
	)
	simulate_physics(480)
	local position = sphere_ent.transform:GetPosition()
	sphere_ent:Remove()
	platform_ent:Remove()
	T(math.abs(position.z))["<"](0.2)
	T(position.y)["<"](bottom_y - sphere_radius - 0.2)
end)
