local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local HeightmapShape = import("goluwa/physics/shapes/heightmap.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local CCD_FIXED_STEPS = {1 / 60}

local function with_ccd(config)
	config.CCD = true
	return config
end

local function without_auto_ccd(config)
	config.AutoCCD = false
	return config
end

local function with_fixed_step(fixed_dt, callback)
	local previous_fixed_dt = physics.instance.FixedTimeStep
	local previous_accumulator = physics.instance.FrameAccumulator
	local previous_alpha = physics.instance.InterpolationAlpha
	physics.instance.FixedTimeStep = fixed_dt
	physics.instance.FrameAccumulator = 0
	physics.instance.InterpolationAlpha = 0
	local ok, err = xpcall(callback, debug.traceback)
	physics.instance.FixedTimeStep = previous_fixed_dt
	physics.instance.FrameAccumulator = previous_accumulator or 0
	physics.instance.InterpolationAlpha = previous_alpha or 0

	if not ok then
		error(string.format("[fixed_dt=%.6f] %s", fixed_dt, tostring(err)), 0)
	end
end

local function create_heightmap_shape(resolution, size, fn)
	return HeightmapShape.New{
		Samples = HeightmapShape.SamplesFromFunction(resolution + 1, resolution + 1, fn),
		SamplesX = resolution + 1,
		SamplesZ = resolution + 1,
		Size = Vec2(size, size),
	}
end

local function create_flat_heightmap_ground(name)
	local resolution = 24
	local ground = Entity.New({Name = name})
	ground:AddComponent("transform")
	ground.transform:SetPosition(Vec3(0, 0, 0))
	ground:AddComponent(
		"rigid_body",
		{
			Shape = create_heightmap_shape(resolution, 18, function()
				return 0.5
			end),
			MotionType = "static",
			WorldGeometry = true,
			Friction = 0.9,
			Restitution = 0,
		}
	)
	return ground
end

T.TestPhysics("Capsule rigid body lands on ground mesh", function()
	local ground = test_helpers.CreateFlatGround("capsule_ground", 16)
	local body_ent = Entity.New({Name = "capsule_body"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(0, 4, 0))
	local body = body_ent:AddComponent(
		"rigid_body",
		{
			Shape = CapsuleShape.New(0.5, 2.0),
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	test_helpers.Simulate(300)
	local position = body_ent.transform:GetPosition()
	T(body:GetGrounded())["=="](true)
	T(position.y)[">="](0.95)
	T(position.y)["<="](1.05)
	T(body:GetGroundNormal().y)[">"](0.9)
	body_ent:Remove()
	ground:Remove()
end)

T.TestPhysics("Tilted capsule on terrain can rotate out of its initial lean", function()
	local ground = create_flat_heightmap_ground("capsule_tilt_ground")
	local body_ent = Entity.New({Name = "capsule_tilt_body"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(0, 2.0, 0))
	body_ent.transform:SetAngles(Deg3(0, 0, 45))
	local body = body_ent:AddComponent(
		"rigid_body",
		{
			Shape = CapsuleShape.New(0.5, 3.2),
			LinearDamping = 0,
			AngularDamping = 0,
			Friction = 0.9,
		}
	)

	with_fixed_step(1 / 60, function()
		test_helpers.SimulateSettled(body, 240, 1 / 60)
	end)

	local axis = body:GetRotation():VecMul(Vec3(0, 1, 0)):GetNormalized()
	T(math.abs(math.abs(axis.y) - 0.70710678118655))[">"](0.12)
	body_ent:Remove()
	ground:Remove()
end)

T.TestPhysics("Rolling capsule on terrain does not keep spinning in place", function()
	local ground = create_flat_heightmap_ground("capsule_roll_ground")
	local body_ent = Entity.New({Name = "capsule_roll_body"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(0, 3.2, 0))
	body_ent.transform:SetAngles(Deg3(0, 0, 55))
	local body = body_ent:AddComponent(
		"rigid_body",
		{
			Shape = CapsuleShape.New(0.5, 3.2),
			LinearDamping = 0,
			AngularDamping = 0,
			Friction = 0.9,
		}
	)
	body:SetAngularVelocity(Vec3(0, 0, 5.5))

	with_fixed_step(1 / 60, function()
		test_helpers.SimulateSettled(body, 420, 1 / 60)
	end)

	T(body:GetGrounded())["=="](true)
	T(body:GetAwake())["=="](false)
	T(body:GetVelocity():GetLength())["<"](0.08)
	T(body:GetAngularVelocity():GetLength())["<"](0.1)
	body_ent:Remove()
	ground:Remove()
end)

T.TestPhysics("Rolling capsule on shallow terrain rolls to a stop", function()
	local resolution = 32
	local ground = Entity.New({Name = "capsule_debug_roll_ground"})
	ground:AddComponent("transform")
	ground.transform:SetPosition(Vec3(0, 0, 0))
	ground:AddComponent(
		"rigid_body",
		{
			Shape = create_heightmap_shape(resolution, 24, function(x, z)
				local nx = x / resolution * math.pi * 2
				local nz = z / resolution * math.pi * 2
				return 0.25 + (math.sin(nx * 1.25) * 0.03 + math.cos(nz * 0.8) * 0.01) * 1.5
			end),
			MotionType = "static",
			WorldGeometry = true,
			Friction = 0.9,
			Restitution = 0,
		}
	)
	local body_ent = Entity.New({Name = "capsule_debug_roll_body"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(-6, 2.2, 0))
	body_ent.transform:SetAngles(Deg3(0, 0, 82))
	local body = body_ent:AddComponent(
		"rigid_body",
		{
			Shape = CapsuleShape.New(0.5, 3.2),
			LinearDamping = 0,
			AngularDamping = 0,
			Friction = 0.9,
		}
	)
	body:SetVelocity(Vec3(3.4, 0, 0))
	body:SetAngularVelocity(Vec3(0, 0, -5.6))

	with_fixed_step(1 / 60, function()
		test_helpers.Simulate(120, 1 / 60)
	end)

	local velocity = body:GetVelocity()
	local angular_speed = body:GetAngularVelocity():GetLength()
	local horizontal_speed = Vec3(velocity.x, 0, velocity.z):GetLength()
	T(body:GetGrounded())["=="](true)
	-- friction brings the roll to rest within 2 s instead of sliding forever
	T(horizontal_speed)["<"](0.5)
	T(angular_speed)["<"](0.6)
	body_ent:Remove()
	ground:Remove()
end)

T.Test("Capsule shape mass properties include cylindrical section", function()
	local short = CapsuleShape.New(0.5, 1.0)
	local tall = CapsuleShape.New(0.5, 3.0)
	local mock_body = test_helpers.CreateStubBody{
		AutomaticMass = true,
		Density = 1,
		IsDynamic = true,
	}
	local short_mass = short:GetMassProperties(mock_body)
	local tall_mass = tall:GetMassProperties(mock_body)
	local short_half = short:GetHalfExtents()
	local tall_half = tall:GetHalfExtents()
	T(tall_mass)[">"](short_mass)
	T(short_half.y)["=="](0.5)
	T(tall_half.y)["=="](1.5)
end)

T.TestPhysics("Capsule rigid body can rest on static box", function()
	local ground = test_helpers.CreateFlatGround("capsule_box_ground", 16)
	local box_ent = Entity.New({Name = "capsule_static_box"})
	box_ent:AddComponent("transform")
	box_ent.transform:SetPosition(Vec3(0, 1, 0))
	box_ent:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(2, 1, 2)),
			Size = Vec3(2, 1, 2),
			MotionType = "static",
		}
	)
	local capsule_ent = Entity.New({Name = "capsule_on_box"})
	capsule_ent:AddComponent("transform")
	capsule_ent.transform:SetPosition(Vec3(0, 4, 0))
	local capsule = capsule_ent:AddComponent(
		"rigid_body",
		{
			Shape = CapsuleShape.New(0.5, 2.0),
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	test_helpers.Simulate(240)
	local position = capsule_ent.transform:GetPosition()
	T(capsule:GetGrounded())["=="](true)
	T(position.y)[">="](2.05)
	T(position.y)["<="](2.55)
	capsule_ent:Remove()
	box_ent:Remove()
	ground:Remove()
end)

T.TestPhysics("Capsule rigid body rolls off rotated static box instead of resting on its AABB", function()
	local ground = test_helpers.CreateFlatGround("capsule_rotated_box_ground", 20)
	local ramp_ent = Entity.New({Name = "capsule_rotated_box"})
	ramp_ent:AddComponent("transform")
	ramp_ent.transform:SetPosition(Vec3(0, 1.5, 0))
	ramp_ent.transform:SetAngles(Deg3(0, 0, -35))
	ramp_ent:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(4, 1, 4)),
			Size = Vec3(4, 1, 4),
			MotionType = "static",
		}
	)
	local capsule_ent = Entity.New({Name = "capsule_rotated_box_body"})
	capsule_ent:AddComponent("transform")
	capsule_ent.transform:SetPosition(Vec3(0, 5, 0))
	local capsule = capsule_ent:AddComponent(
		"rigid_body",
		{
			Shape = CapsuleShape.New(0.5, 2.0),
			LinearDamping = 0,
			AngularDamping = 0,
			Friction = 0.4,
		}
	)
	test_helpers.Simulate(240)
	local position = capsule_ent.transform:GetPosition()
	T(math.abs(position.x))[">"](0.45)
	T(position.y)["<"](5.0)
	T(capsule:GetGroundNormal().y)[">"](0.2)
	capsule_ent:Remove()
	ramp_ent:Remove()
	ground:Remove()
end)

T.TestPhysics("Fast capsule tunnels through thin static box with auto CCD disabled", function()
	local blocker_ent = Entity.New({Name = "capsule_discrete_blocker"})
	blocker_ent:AddComponent("transform")
	blocker_ent.transform:SetPosition(Vec3(0, 1, 0))
	blocker_ent:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(6, 0.2, 6)),
			Size = Vec3(6, 0.2, 6),
			MotionType = "static",
		}
	)
	local capsule_ent = Entity.New({Name = "capsule_discrete_body"})
	capsule_ent:AddComponent("transform")
	capsule_ent.transform:SetPosition(Vec3(0, 8, 0))
	local capsule = capsule_ent:AddComponent(
		"rigid_body",
		without_auto_ccd{
			Shape = CapsuleShape.New(0.5, 2.0),
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
		}
	)
	capsule:SetVelocity(Vec3(0, -320, 0))
	test_helpers.Simulate(1, 1 / 10)
	local position = capsule_ent.transform:GetPosition()
	blocker_ent:Remove()
	capsule_ent:Remove()
	T(position.y)["<"](0)
end)

T.TestPhysics("Fast capsule does not tunnel through thin static box when CCD is enabled", function()
	local blocker_ent = Entity.New({Name = "capsule_ccd_blocker"})
	blocker_ent:AddComponent("transform")
	blocker_ent.transform:SetPosition(Vec3(0, 1, 0))
	blocker_ent:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(6, 0.2, 6)),
			Size = Vec3(6, 0.2, 6),
			MotionType = "static",
		}
	)
	local capsule_ent = Entity.New({Name = "capsule_ccd_body"})
	capsule_ent:AddComponent("transform")
	capsule_ent.transform:SetPosition(Vec3(0, 8, 0))
	local capsule = capsule_ent:AddComponent(
		"rigid_body",
		with_ccd{
			Shape = CapsuleShape.New(0.5, 2.0),
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
		}
	)
	capsule:SetVelocity(Vec3(0, -320, 0))
	test_helpers.Simulate(1, 1 / 10)
	local position = capsule_ent.transform:GetPosition()
	blocker_ent:Remove()
	capsule_ent:Remove()
	T(position.y)[">="](2.05)
	T(math.abs(position.x))["<"](0.1)
	T(math.abs(position.z))["<"](0.1)
end)

T.TestPhysics("Fast capsule does not tunnel through static sphere", function()
	local blocker_ent = Entity.New({Name = "capsule_ccd_sphere_blocker"})
	blocker_ent:AddComponent("transform")
	blocker_ent.transform:SetPosition(Vec3(0, 1.5, 0))
	blocker_ent:AddComponent(
		"rigid_body",
		{
			Shape = SphereShape.New(0.7),
			Radius = 0.7,
			MotionType = "static",
		}
	)
	local capsule_ent = Entity.New({Name = "capsule_ccd_vs_sphere_body"})
	capsule_ent:AddComponent("transform")
	capsule_ent.transform:SetPosition(Vec3(-8, 1.5, 0))
	local capsule = capsule_ent:AddComponent(
		"rigid_body",
		with_ccd{
			Shape = CapsuleShape.New(0.5, 2.0),
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
		}
	)
	capsule:SetVelocity(Vec3(320, 0, 0))
	test_helpers.Simulate(1, 1 / 20)
	local position = capsule_ent.transform:GetPosition()
	blocker_ent:Remove()
	capsule_ent:Remove()
	T(position.x)["<"](-0.6)
	T(math.abs(position.y - 1.5))["<"](0.2)
	T(math.abs(position.z))["<"](0.1)
end)

T.TestPhysics("Fast sphere does not tunnel through static capsule", function()
	local blocker_ent = Entity.New({Name = "sphere_ccd_capsule_blocker"})
	blocker_ent:AddComponent("transform")
	blocker_ent.transform:SetPosition(Vec3(0, 1.5, 0))
	blocker_ent:AddComponent(
		"rigid_body",
		{
			Shape = CapsuleShape.New(0.5, 2.0),
			MotionType = "static",
		}
	)
	local sphere_ent = Entity.New({Name = "sphere_ccd_vs_capsule_body"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(-8, 1.5, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		with_ccd{
			Shape = SphereShape.New(0.6),
			Radius = 0.6,
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
		}
	)
	sphere:SetVelocity(Vec3(320, 0, 0))
	test_helpers.Simulate(1, 1 / 20)
	local position = sphere_ent.transform:GetPosition()
	blocker_ent:Remove()
	sphere_ent:Remove()
	T(position.x)["<"](-0.6)
	T(math.abs(position.y - 1.5))["<"](0.2)
	T(math.abs(position.z))["<"](0.1)
end)

T.TestPhysics("Fast capsule does not tunnel through static capsule", function()
	local blocker_ent = Entity.New({Name = "capsule_ccd_capsule_blocker"})
	blocker_ent:AddComponent("transform")
	blocker_ent.transform:SetPosition(Vec3(0, 1.5, 0))
	blocker_ent:AddComponent(
		"rigid_body",
		{
			Shape = CapsuleShape.New(0.5, 2.0),
			MotionType = "static",
		}
	)
	local capsule_ent = Entity.New({Name = "capsule_ccd_vs_capsule_body"})
	capsule_ent:AddComponent("transform")
	capsule_ent.transform:SetPosition(Vec3(-8, 1.5, 0))
	local capsule = capsule_ent:AddComponent(
		"rigid_body",
		with_ccd{
			Shape = CapsuleShape.New(0.5, 2.0),
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
		}
	)
	capsule:SetVelocity(Vec3(320, 0, 0))
	test_helpers.Simulate(1, 1 / 20)
	local position = capsule_ent.transform:GetPosition()
	blocker_ent:Remove()
	capsule_ent:Remove()
	T(position.x)["<"](-0.8)
	T(math.abs(position.y - 1.5))["<"](0.2)
	T(math.abs(position.z))["<"](0.1)
end)

T.TestPhysics("Fast capsule CCD remains stable at smaller fixed steps against thin static box", function()
	for _, fixed_dt in ipairs(CCD_FIXED_STEPS) do
		with_fixed_step(fixed_dt, function()
			local blocker_ent = Entity.New({Name = "capsule_ccd_fixed_step_blocker"})
			blocker_ent:AddComponent("transform")
			blocker_ent.transform:SetPosition(Vec3(0, 1, 0))
			blocker_ent:AddComponent(
				"rigid_body",
				{
					Shape = BoxShape.New(Vec3(6, 0.2, 6)),
					Size = Vec3(6, 0.2, 6),
					MotionType = "static",
				}
			)
			local capsule_ent = Entity.New({Name = "capsule_ccd_fixed_step_body"})
			capsule_ent:AddComponent("transform")
			capsule_ent.transform:SetPosition(Vec3(0, 8, 0))
			local capsule = capsule_ent:AddComponent(
				"rigid_body",
				with_ccd{
					Shape = CapsuleShape.New(0.5, 2.0),
					LinearDamping = 0,
					AngularDamping = 0,
					MaxLinearSpeed = 1000,
				}
			)
			capsule:SetVelocity(Vec3(0, -320, 0))
			test_helpers.Simulate(1, 1 / 10)
			local position = capsule_ent.transform:GetPosition()
			blocker_ent:Remove()
			capsule_ent:Remove()
			T(position.y)[">="](2.05)
		end)
	end
end)

T.TestPhysics("Fast capsule CCD remains stable at smaller fixed steps against static capsule", function()
	for _, fixed_dt in ipairs(CCD_FIXED_STEPS) do
		with_fixed_step(fixed_dt, function()
			local blocker_ent = Entity.New({Name = "capsule_ccd_fixed_step_capsule_blocker"})
			blocker_ent:AddComponent("transform")
			blocker_ent.transform:SetPosition(Vec3(0, 1.5, 0))
			blocker_ent:AddComponent(
				"rigid_body",
				{
					Shape = CapsuleShape.New(0.5, 2.0),
					MotionType = "static",
				}
			)
			local capsule_ent = Entity.New({Name = "capsule_ccd_fixed_step_capsule_body"})
			capsule_ent:AddComponent("transform")
			capsule_ent.transform:SetPosition(Vec3(-8, 1.5, 0))
			local capsule = capsule_ent:AddComponent(
				"rigid_body",
				with_ccd{
					Shape = CapsuleShape.New(0.5, 2.0),
					GravityScale = 0,
					LinearDamping = 0,
					AngularDamping = 0,
					MaxLinearSpeed = 1000,
				}
			)
			capsule:SetVelocity(Vec3(320, 0, 0))
			test_helpers.Simulate(1, 1 / 20)
			local position = capsule_ent.transform:GetPosition()
			blocker_ent:Remove()
			capsule_ent:Remove()
			T(position.x)["<"](-0.8)
			T(math.abs(position.y - 1.5))["<"](0.2)
		end)
	end
end)

T.TestPhysics("Rolling capsule on flat box settles without sinking or jittering", function()
	local ground_ent = Entity.New({Name = "capsule_roll_flat_ground"})
	ground_ent:AddComponent("transform")
	ground_ent.transform:SetPosition(Vec3(0, -0.5, 0))
	ground_ent:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(40, 1, 40)),
			MotionType = "static",
			Friction = 0.4,
		}
	)
	local capsule_ent = Entity.New({Name = "capsule_roll_flat_body"})
	capsule_ent:AddComponent("transform")
	capsule_ent.transform:SetPosition(Vec3(-8, 3, 0))
	capsule_ent.transform:SetAngles(Deg3(18, 0, 0))
	local capsule = capsule_ent:AddComponent(
		"rigid_body",
		{
			Shape = CapsuleShape.New(0.5, 2.0),
			LinearDamping = 0,
			AngularDamping = 0,
			Friction = 0.4,
		}
	)
	capsule:SetVelocity(Vec3(2, 0, 0))
	capsule:SetAngularVelocity(Vec3(-3, 0, 0))
	local ys = {}

	for step = 1, 600 do
		physics.Update(1 / 120)

		if step > 480 then ys[#ys + 1] = capsule_ent.transform:GetPosition().y end
	end

	local min_y, max_y = math.huge, -math.huge

	for _, y in ipairs(ys) do
		min_y = math.min(min_y, y)
		max_y = math.max(max_y, y)
	end

	-- the box top is at y = 0; the center stays inside the capsule vertical
	-- extent whether rolling tilted or standing upright
	T(max_y)["<="](1.15)
	T(min_y)[">="](0.05)
	-- settled rolling must not bounce or jitter
	T(max_y - min_y)["<="](0.05)
	T(capsule:GetGrounded())["=="](true)
	capsule_ent:Remove()
	ground_ent:Remove()
end)

T.TestPhysics("Capsule spawned deep inside a static box recovers to the surface", function()
	local box_ent = Entity.New({Name = "capsule_deep_box"})
	box_ent:AddComponent("transform")
	box_ent.transform:SetPosition(Vec3(0, 1, 0))
	box_ent:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(2, 1, 2)),
			Size = Vec3(2, 1, 2),
			MotionType = "static",
		}
	)
	local capsule_ent = Entity.New({Name = "capsule_deep_body"})
	capsule_ent:AddComponent("transform")
	-- box top is at y = 1.5, capsule bottom at 0.7: 0.8 deep in the box
	capsule_ent.transform:SetPosition(Vec3(0, 1.7, 0))
	local capsule = capsule_ent:AddComponent(
		"rigid_body",
		{
			Shape = CapsuleShape.New(0.5, 2.0),
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	test_helpers.Simulate(360)
	local position = capsule_ent.transform:GetPosition()
	T(position.y)[">="](2.0)
	T(position.y)["<="](2.6)
	T(capsule:GetGrounded())["=="](true)
	capsule_ent:Remove()
	box_ent:Remove()
end)

T.TestPhysics("Parallel capsules overlapping side by side settle stably", function()
	local blocker_ent = Entity.New({Name = "capsule_parallel_blocker"})
	blocker_ent:AddComponent("transform")
	blocker_ent.transform:SetPosition(Vec3(0, 0, 0))
	blocker_ent:AddComponent(
		"rigid_body",
		{
			Shape = CapsuleShape.New(0.5, 2.0),
			MotionType = "static",
		}
	)
	local capsule_ent = Entity.New({Name = "capsule_parallel_body"})
	capsule_ent:AddComponent("transform")
	capsule_ent.transform:SetPosition(Vec3(0.8, 0, 0))
	local capsule = capsule_ent:AddComponent(
		"rigid_body",
		{
			Shape = CapsuleShape.New(0.5, 2.0),
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	test_helpers.Simulate(300)
	local position = capsule_ent.transform:GetPosition()
	-- pushed apart to the combined radii, still upright next to the blocker
	T(math.abs(position.x))[">="](0.9)
	T(math.abs(position.x))["<="](1.15)
	T(math.abs(position.y))["<"](0.15)
	T(math.abs(position.z))["<"](0.15)
	local velocity = capsule:GetVelocity()
	T(velocity:GetLength())["<"](0.05)
	capsule_ent:Remove()
	blocker_ent:Remove()
end)
