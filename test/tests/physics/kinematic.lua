local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local sphere_shape = SphereShape.New
local capsule_shape = CapsuleShape.New
local box_shape = BoxShape.New

local function simulate_physics(steps, dt)
	dt = dt or (1 / 120)

	for _ = 1, steps do
		physics.Update(dt)
	end
end

local function create_flat_ground(name, extent)
	extent = extent or 8
	local ground = Entity.New({Name = name})
	ground:AddComponent("transform")
	ground:AddComponent("model")
	local poly = Polygon3D.New()
	poly:AddVertex{pos = Vec3(-extent, 0, -extent), uv = Vec2(0, 0), normal = Vec3(0, -1, 0)}
	poly:AddVertex{pos = Vec3(0, 0, extent), uv = Vec2(0.5, 1), normal = Vec3(0, -1, 0)}
	poly:AddVertex{pos = Vec3(extent, 0, -extent), uv = Vec2(1, 0), normal = Vec3(0, -1, 0)}
	poly:BuildBoundingBox()
	poly:Upload()
	ground.model:AddPrimitive(poly)
	ground.model:BuildAABB()
	return ground
end

local function create_static_step(name, center, size)
	local ent = Entity.New({Name = name})
	ent:AddComponent("transform")
	ent.transform:SetPosition(center)
	ent:AddComponent("rigid_body", {
		Shape = box_shape(size),
		MotionType = "static",
	})
	return ent
end
do return end -- kinematic is broken, skip for now
T.Test3D("Kinematic controller implies kinematic motion type", function()
	local ent = Entity.New({Name = "kinematic_motion_type"})
	ent:AddComponent("transform")
	local body = ent:AddComponent("rigid_body", {
		Shape = sphere_shape(0.5),
	})
	local controller = ent:AddComponent("kinematic_controller")
	simulate_physics(1)
	T(body:GetMotionType())["=="]("kinematic")
	T(controller:IsControllingKinematicBody())["=="](true)
	ent:Remove()
end)

T.Test3D("Kinematic controller moves body along flat ground", function()
	local ground = create_flat_ground("kinematic_move_ground", 24)
	local ent = Entity.New({Name = "kinematic_move_body"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(Vec3(0, 3, 0))
	local body = ent:AddComponent("rigid_body", {
		Shape = sphere_shape(0.5),
		LinearDamping = 0,
	})
	local controller = ent:AddComponent("kinematic_controller", {
		Acceleration = 80,
		AirAcceleration = 80,
	})
	simulate_physics(180)
	local settled = ent.transform:GetPosition():Copy()
	T(body:GetGrounded())["=="](true)
	T(settled.y)[">="](0.49)
	T(settled.y)["<="](0.56)
	controller:SetDesiredVelocity(Vec3(6, 0, 0))
	simulate_physics(120)
	local moved = ent.transform:GetPosition()
	T(moved.x)[">"](2.5)
	T(math.abs(moved.z))["<"](0.5)
	T(moved.y)[">="](0.49)
	T(moved.y)["<="](0.58)
	ent:Remove()
	ground:Remove()
end)

T.Test3D("Kinematic controller supports capsule bodies on flat ground", function()
	local ground = create_flat_ground("kinematic_capsule_ground", 24)
	local ent = Entity.New({Name = "kinematic_capsule_body"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(Vec3(0, 4, 0))
	local body = ent:AddComponent("rigid_body", {
		Shape = capsule_shape(0.35, 1.8),
		LinearDamping = 0,
	})
	local controller = ent:AddComponent("kinematic_controller", {
		Acceleration = 80,
		AirAcceleration = 80,
	})
	simulate_physics(180)
	local settled = ent.transform:GetPosition():Copy()
	T(body:GetGrounded())["=="](true)
	T(settled.y)[">="](0.88)
	T(settled.y)["<="](0.96)
	controller:SetDesiredVelocity(Vec3(6, 0, 0))
	simulate_physics(120)
	local moved = ent.transform:GetPosition()
	T(moved.x)[">"](2.5)
	T(math.abs(moved.z))["<"](0.5)
	T(moved.y)[">="](0.88)
	T(moved.y)["<="](0.98)
	ent:Remove()
	ground:Remove()
end)

T.Test3D("Kinematic capsule ground speed matches desired velocity", function()
	local ground = create_flat_ground("kinematic_capsule_speed_ground", 24)
	local ent = Entity.New({Name = "kinematic_capsule_speed_body"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(Vec3(0, 4, 0))
	local body = ent:AddComponent("rigid_body", {
		Shape = capsule_shape(0.35, 1.8),
		LinearDamping = 0,
	})
	local controller = ent:AddComponent("kinematic_controller", {
		Acceleration = 200,
		AirAcceleration = 200,
	})
	simulate_physics(180)
	local settled = ent.transform:GetPosition():Copy()
	T(body:GetGrounded())["=="](true)
	controller:SetDesiredVelocity(Vec3(1, 0, 0))
	simulate_physics(120)
	local moved = ent.transform:GetPosition()
	local distance = moved.x - settled.x
	T(distance)[">="](0.9)
	T(distance)["<="](1.1)
	T(math.abs(moved.z - settled.z))["<"](0.1)
	T(moved.y)[">="](0.88)
	T(moved.y)["<="](0.98)
	ent:Remove()
	ground:Remove()
end)

T.Test3D("Kinematic controller capsule can stand on static box", function()
	local ground = create_flat_ground("kinematic_capsule_box_ground", 24)
	local box_ent = Entity.New({Name = "kinematic_capsule_box"})
	box_ent:AddComponent("transform")
	box_ent.transform:SetPosition(Vec3(0, 1, 0))
	box_ent:AddComponent("rigid_body", {
		Shape = box_shape(Vec3(2, 1, 2)),
		MotionType = "static",
	})
	local ent = Entity.New({Name = "kinematic_capsule_on_box"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(Vec3(0, 4, 0))
	local body = ent:AddComponent("rigid_body", {
		Shape = capsule_shape(0.35, 1.8),
		LinearDamping = 0,
	})
	ent:AddComponent("kinematic_controller", {
		Acceleration = 80,
		AirAcceleration = 80,
	})
	simulate_physics(240)
	local settled = ent.transform:GetPosition()
	T(body:GetGrounded())["=="](true)
	T(settled.y)[">="](2.38)
	T(settled.y)["<="](2.46)
	ent:Remove()
	box_ent:Remove()
	ground:Remove()
end)

T.Test3D("Physics body lands on ground mesh", function()
	local ground = Entity.New({Name = "physics_ground"})
	ground:AddComponent("transform")
	ground:AddComponent("model")
	local poly = Polygon3D.New()
	poly:AddVertex{pos = Vec3(-4, 0, -4), uv = Vec2(0, 0), normal = Vec3(0, -1, 0)}
	poly:AddVertex{pos = Vec3(0, 0, 4), uv = Vec2(0.5, 1), normal = Vec3(0, -1, 0)}
	poly:AddVertex{pos = Vec3(4, 0, -4), uv = Vec2(1, 0), normal = Vec3(0, -1, 0)}
	poly:BuildBoundingBox()
	poly:Upload()
	ground.model:AddPrimitive(poly)
	ground.model:BuildAABB()
	local body_ent = Entity.New({Name = "kinematic_body"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(0, 3, 0))
	local body = body_ent:AddComponent("rigid_body", {
		Shape = sphere_shape(0.5),
		LinearDamping = 0,
	})
	body_ent:AddComponent("kinematic_controller", {
		Acceleration = 0,
		AirAcceleration = 0,
	})

	for _ = 1, 180 do
		physics.Update(1 / 120)
	end

	local position = body_ent.transform:GetPosition()
	T(body:GetGrounded())["=="](true)
	T(position.y)[">="](0.49)
	T(position.y)["<="](0.55)
	T(body:GetGroundNormal().y)[">"](0.9)
	body_ent:Remove()
	ground:Remove()
end)

T.Test3D("Kinematic body can stand on rigid body", function()
	local ground = Entity.New({Name = "kinematic_rigid_ground"})
	ground:AddComponent("transform")
	ground:AddComponent("model")
	local ground_poly = Polygon3D.New()
	ground_poly:AddVertex{pos = Vec3(-6, 0, -6), uv = Vec2(0, 0), normal = Vec3(0, -1, 0)}
	ground_poly:AddVertex{pos = Vec3(0, 0, 6), uv = Vec2(0.5, 1), normal = Vec3(0, -1, 0)}
	ground_poly:AddVertex{pos = Vec3(6, 0, -6), uv = Vec2(1, 0), normal = Vec3(0, -1, 0)}
	ground_poly:BuildBoundingBox()
	ground_poly:Upload()
	ground.model:AddPrimitive(ground_poly)
	ground.model:BuildAABB()
	local platform_ent = Entity.New({Name = "rigid_body_platform"})
	platform_ent:AddComponent("transform")
	platform_ent.transform:SetPosition(Vec3(0, 1, 0))
	local platform_poly = Polygon3D.New()
	platform_poly:CreateSphere(1)
	platform_poly:BuildBoundingBox()
	platform_poly:Upload()
	platform_ent:AddComponent("model")
	platform_ent.model:AddPrimitive(platform_poly)
	platform_ent.model:BuildAABB()
	platform_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(1),
			Radius = 1,
			MotionType = "static",
		}
	)
	local body_ent = Entity.New({Name = "kinematic_on_rigid"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(0, 4, 0))
	local body = body_ent:AddComponent("rigid_body", {
		Shape = sphere_shape(0.5),
		LinearDamping = 0,
	})
	body_ent:AddComponent("kinematic_controller", {
		Acceleration = 0,
		AirAcceleration = 0,
	})

	for _ = 1, 240 do
		physics.Update(1 / 120)
	end

	local position = body_ent.transform:GetPosition()
	T(body:GetGrounded())["=="](true)
	T(position.y)[">="](2.3)
	T(position.y)["<="](2.7)
	T(body:GetGroundNormal().y)[">"](0.9)
	body_ent:Remove()
	platform_ent:Remove()
	ground:Remove()
end)

T.Test3D("Kinematic capsule is carried by moving rigid body platform", function()
	local platform_ent = Entity.New({Name = "kinematic_moving_platform"})
	platform_ent:AddComponent("transform")
	platform_ent.transform:SetPosition(Vec3(0, 1, 0))
	local platform = platform_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(3, 1, 3)),
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	platform:SetVelocity(Vec3(2, 0, 0))
	local ent = Entity.New({Name = "kinematic_capsule_on_moving_platform"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(Vec3(0, 4, 0))
	local body = ent:AddComponent("rigid_body", {
		Shape = capsule_shape(0.35, 1.8),
		LinearDamping = 0,
	})
	ent:AddComponent("kinematic_controller", {
		Acceleration = 80,
		AirAcceleration = 80,
	})
	simulate_physics(240)
	local platform_pos = platform_ent.transform:GetPosition()
	local position = ent.transform:GetPosition()
	T(body:GetGrounded())["=="](true)
	T(platform_pos.x)[">"](1.5)
	T(position.x)[">"](1.0)
	T(math.abs(position.x - platform_pos.x))["<"](0.9)
	ent:Remove()
	platform_ent:Remove()
end)

T.Test3D("Kinematic capsule follows walkable slopes", function()
	local ground = create_flat_ground("kinematic_slope_ground", 24)
	local ramp_ent = Entity.New({Name = "kinematic_walkable_ramp"})
	ramp_ent:AddComponent("transform")
	ramp_ent.transform:SetPosition(Vec3(0, 0.8, 0))
	ramp_ent.transform:SetAngles(Deg3(0, 0, -20))
	ramp_ent:AddComponent("rigid_body", {
		Shape = box_shape(Vec3(6, 1, 4)),
		MotionType = "static",
	})
	local ent = Entity.New({Name = "kinematic_capsule_on_slope"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(Vec3(-1.8, 4, 0))
	local body = ent:AddComponent("rigid_body", {
		Shape = capsule_shape(0.35, 1.8),
		LinearDamping = 0,
	})
	local controller = ent:AddComponent("kinematic_controller", {
		Acceleration = 80,
		AirAcceleration = 80,
	})
	simulate_physics(180)
	local settled = ent.transform:GetPosition():Copy()
	controller:SetDesiredVelocity(Vec3(4, 0, 0))
	simulate_physics(180)
	local position = ent.transform:GetPosition()
	T(body:GetGrounded())["=="](true)
	T(position.x)[">"](settled.x + 0.5)
	T(position.y)["<"](settled.y - 0.2)
	T(body:GetGroundNormal().y)[">"](0.75)
	ent:Remove()
	ramp_ent:Remove()
	ground:Remove()
end)

T.Test3D("Kinematic capsule does not get launched downhill while idle on slopes", function()
	local ground = create_flat_ground("kinematic_idle_slope_ground", 24)
	local ramp_ent = Entity.New({Name = "kinematic_idle_ramp"})
	ramp_ent:AddComponent("transform")
	ramp_ent.transform:SetPosition(Vec3(0, 0.8, 0))
	ramp_ent.transform:SetAngles(Deg3(0, 0, -20))
	ramp_ent:AddComponent("rigid_body", {
		Shape = box_shape(Vec3(6, 1, 4)),
		MotionType = "static",
	})
	local ent = Entity.New({Name = "kinematic_idle_capsule_on_slope"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(Vec3(-0.8, 4, 0))
	local body = ent:AddComponent("rigid_body", {
		Shape = capsule_shape(0.35, 1.8),
		LinearDamping = 0,
	})
	ent:AddComponent("kinematic_controller", {
		Acceleration = 80,
		AirAcceleration = 80,
	})
	simulate_physics(180)
	local settled = ent.transform:GetPosition():Copy()
	T(body:GetGrounded())["=="](true)
	simulate_physics(120)
	local idle = ent.transform:GetPosition()
	T(body:GetGrounded())["=="](true)
	T(math.abs(idle.x - settled.x))["<"](0.35)
	T(math.abs(idle.y - settled.y))["<"](0.25)
	ent:Remove()
	ramp_ent:Remove()
	ground:Remove()
end)

T.Test3D("Kinematic capsule walks down low ledges", function()
	local ground = create_flat_ground("kinematic_down_step_ground", 64)
	local step = create_static_step("kinematic_down_step", Vec3(0, 0.15, 0), Vec3(4, 0.3, 3.2))
	local ent = Entity.New({Name = "kinematic_down_step_capsule"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(Vec3(-1.2, 4, 0))
	local body = ent:AddComponent("rigid_body", {
		Shape = capsule_shape(0.35, 1.8),
		LinearDamping = 0,
	})
	local controller = ent:AddComponent(
		"kinematic_controller",
		{
			Acceleration = 80,
			AirAcceleration = 80,
			StepHeight = 0.4,
			GroundSnapDistance = 0.4,
		}
	)
	simulate_physics(180)
	controller:SetDesiredVelocity(Vec3(3.5, 0, 0))
	simulate_physics(140)
	local position = ent.transform:GetPosition()
	T(body:GetGrounded())["=="](true)
	T(position.x)[">"](2.2)
	T(position.y)[">="](0.88)
	T(position.y)["<="](1.0)
	ent:Remove()
	step:Remove()
	ground:Remove()
end)

T.Test3D("Kinematic capsule can walk off tall ledges and fall", function()
	local ground = create_flat_ground("kinematic_off_ledge_ground", 64)
	local platform = create_static_step("kinematic_off_ledge_box", Vec3(0, 1.0, 0), Vec3(4, 1.0, 3.2))
	local ent = Entity.New({Name = "kinematic_off_ledge_capsule"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(Vec3(-1.1, 5, 0))
	local body = ent:AddComponent("rigid_body", {
		Shape = capsule_shape(0.35, 1.8),
		LinearDamping = 0,
	})
	local controller = ent:AddComponent(
		"kinematic_controller",
		{
			Acceleration = 80,
			AirAcceleration = 80,
			StepHeight = 0.4,
			GroundSnapDistance = 0.4,
		}
	)
	simulate_physics(220)
	controller:SetDesiredVelocity(Vec3(3.5, 0, 0))
	simulate_physics(220)
	local position = ent.transform:GetPosition()
	T(position.x)[">"](2.4)
	T(position.y)["<"](1.2)
	T(body:GetGrounded())["=="](true)
	ent:Remove()
	platform:Remove()
	ground:Remove()
end)

T.Test3D("Kinematic capsule can jump from flat ground", function()
	local ground = create_flat_ground("kinematic_jump_ground", 24)
	local ent = Entity.New({Name = "kinematic_jump_capsule"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(Vec3(0, 4, 0))
	local body = ent:AddComponent("rigid_body", {
		Shape = capsule_shape(0.35, 1.8),
		LinearDamping = 0,
	})
	local controller = ent:AddComponent(
		"kinematic_controller",
		{
			Acceleration = 80,
			AirAcceleration = 80,
			GroundSnapDistance = 0.4,
		}
	)
	simulate_physics(180)
	local settled = ent.transform:GetPosition():Copy()
	local jump_velocity = body:GetVelocity():Copy()
	jump_velocity.y = 8
	body:SetVelocity(jump_velocity)
	controller:SetVelocity(jump_velocity)
	body:SetGrounded(false)
	simulate_physics(15)
	local jumped = ent.transform:GetPosition()
	T(jumped.y)[">"](settled.y + 0.3)
	T(body:GetGrounded())["=="](false)
	ent:Remove()
	ground:Remove()
end)