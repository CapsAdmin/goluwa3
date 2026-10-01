local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local HingeConstraint = import("goluwa/physics/hinge_constraint.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")

local function spawn_box(name, position, size, config)
	local ent = Entity.New({Name = name})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)

	if config.Rotation then ent.transform:SetRotation(config.Rotation) end

	config.Shape = BoxShape.New(size)
	config.Size = size
	config.Rotation = nil
	return ent, ent:AddComponent("rigid_body", config)
end

local function spawn_wheel(name, position, radius)
	local ent = Entity.New({Name = name})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	return ent,
	ent:AddComponent(
		"rigid_body",
		{
			Shape = SphereShape.New(radius),
			Radius = radius,
			Mass = 1,
			AutomaticMass = false,
			Friction = 0.9,
			MaxLinearSpeed = 1000,
			MaxAngularSpeed = 1000,
		}
	)
end

T.TestPhysics("Hinge to the world swings like a pendulum without stretching", function()
	physics.RemoveAllConstraints()
	local ent, body = spawn_box(
		"hinge_pendulum",
		Vec3(2, 5, 0),
		Vec3(0.4, 0.4, 0.4),
		{
			Mass = 1,
			AutomaticMass = false,
			GravityScale = 1,
		}
	)
	local hinge = HingeConstraint.New(nil, body, Vec3(0, 5, 0), Vec3(0, 0, 1))
	local max_anchor_error = 0
	local max_z = 0
	local lowest = math.huge

	for _ = 1, 240 do
		physics.Update(1 / 120)
		max_anchor_error = math.max(max_anchor_error, hinge:GetAnchorError())
		max_z = math.max(max_z, math.abs(ent.transform:GetPosition().z))
		lowest = math.min(lowest, ent.transform:GetPosition().y)
	end

	local radius = (ent.transform:GetPosition() - Vec3(0, 5, 0)):GetLength()
	hinge:Remove()
	ent:Remove()
	T(max_anchor_error)["<"](0.01)
	T(math.abs(radius - 2))["<"](0.02)
	T(max_z)["<"](0.02)
	T(lowest)["<"](3.2)
end)

T.TestPhysics("Hinged wheel rolls freely about its axis and is pinned to the body", function()
	physics.RemoveAllConstraints()
	local ground_ent = spawn_box(
		"hinge_ground",
		Vec3(0, -0.5, 0),
		Vec3(60, 1, 20),
		{
			MotionType = "static",
			Friction = 0.8,
		}
	)
	local car_ent, car = spawn_box(
		"hinge_car",
		Vec3(0, 0.9, 0),
		Vec3(2, 0.4, 1),
		{
			Mass = 6,
			AutomaticMass = false,
			Friction = 0.2,
		}
	)
	local wheels = {}
	local hinges = {}
	local wheel_ents = {}

	for _, x in ipairs({-0.7, 0.7}) do
		for _, z in ipairs({-0.6, 0.6}) do
			local went, wheel = spawn_wheel("hinge_wheel", Vec3(x, 0.4, z), 0.4)
			wheel_ents[#wheel_ents + 1] = went
			wheels[#wheels + 1] = wheel
			hinges[#hinges + 1] = HingeConstraint.New(car, wheel, Vec3(x, 0.4, z), Vec3(0, 0, 1))
		end
	end

	car:SetVelocity(Vec3(6, 0, 0))

	for _, wheel in ipairs(wheels) do
		wheel:SetVelocity(Vec3(6, 0, 0))
		wheel:SetAngularVelocity(Vec3(0, 0, -15))
	end

	test_helpers.Simulate(120, 1 / 120)
	local max_error = 0

	for _, hinge in ipairs(hinges) do
		max_error = math.max(max_error, hinge:GetAnchorError(), hinge:GetAxisError())
	end

	local car_velocity = car:GetVelocity()
	local wheel_spin = wheels[1]:GetAngularVelocity()
	local car_y = car_ent.transform:GetPosition().y
	local car_z = car_ent.transform:GetPosition().z

	for _, hinge in ipairs(hinges) do
		hinge:Remove()
	end

	for _, went in ipairs(wheel_ents) do
		went:Remove()
	end

	car_ent:Remove()
	ground_ent:Remove()
	T(max_error)["<"](0.01)
	T(car_velocity.x)[">"](3)
	T(math.abs(wheel_spin.z * 0.4 + car_velocity.x))["<"](1)
	T(math.abs(wheel_spin.x))["<"](0.5)
	T(math.abs(wheel_spin.y))["<"](0.5)
	T(math.abs(car_z))["<"](0.1)
	T(car_y)[">"](0.7)
	T(car_y)["<"](1.1)
end)

T.TestPhysics("Jointed bodies do not collide and fall asleep together", function()
	physics.RemoveAllConstraints()
	local ground_ent = spawn_box(
		"hinge_sleep_ground",
		Vec3(0, -0.5, 0),
		Vec3(20, 1, 20),
		{
			MotionType = "static",
			Friction = 0.8,
		}
	)
	local car_ent, car = spawn_box(
		"hinge_sleep_car",
		Vec3(0, 0.9, 0),
		Vec3(2, 0.4, 1),
		{
			Mass = 6,
			AutomaticMass = false,
			Friction = 0.6,
		}
	)
	local went, wheel = spawn_wheel("hinge_sleep_wheel", Vec3(0, 0.4, 0.6), 0.4)
	local hinge = HingeConstraint.New(car, wheel, Vec3(0, 0.4, 0.6), Vec3(0, 0, 1))
	test_helpers.Simulate(480, 1 / 120)
	local car_awake = car:GetAwake()
	local wheel_awake = wheel:GetAwake()
	local ignored = not car:ShouldCollide(wheel)
	hinge:Remove()
	local collides_after_removal = car:ShouldCollide(wheel)
	went:Remove()
	car_ent:Remove()
	ground_ent:Remove()
	T(ignored)["=="](true)
	T(collides_after_removal)["=="](true)
	T(car_awake)["=="](wheel_awake)
end)

T.TestPhysics("Car with hinged wheels rolls down a ramp and topples a stack of boxes", function()
	physics.RemoveAllConstraints()
	local slope = math.rad(18)
	local rotation = Quat(0, 0, math.sin(-slope / 2), math.cos(-slope / 2))
	local ents = {}
	local ramp_length = 16
	local normal = Vec3(math.sin(slope), math.cos(slope), 0)
	local top_center = Vec3(-ramp_length / 2 * math.cos(slope), ramp_length / 2 * math.sin(slope), 0)
	ents[#ents + 1] = spawn_box(
		"car_ground",
		Vec3(0, -0.5, 0),
		Vec3(120, 1, 20),
		{
			MotionType = "static",
			Friction = 0.8,
		}
	)
	ents[#ents + 1] = spawn_box(
		"car_ramp",
		top_center - normal * 0.5,
		Vec3(ramp_length, 1, 8),
		{MotionType = "static", Friction = 0.8, Rotation = rotation}
	)
	local stack = {}

	for i = 0, 3 do
		local ent, body = spawn_box(
			"car_stack",
			Vec3(7, 0.5 + i, 0),
			Vec3(1, 1, 1),
			{
				Mass = 1,
				AutomaticMass = false,
				Friction = 0.6,
			}
		)
		ents[#ents + 1] = ent
		stack[#stack + 1] = body
	end

	local start = top_center * 1.7 + normal * 1.0
	local car_ent, car = spawn_box(
		"car_body",
		start,
		Vec3(2.4, 0.5, 1.2),
		{
			Mass = 10,
			AutomaticMass = false,
			Friction = 0.3,
			Rotation = rotation,
		}
	)
	ents[#ents + 1] = car_ent
	local hinges = {}
	local wheel_bodies = {}
	local axis = rotation:VecMul(Vec3(0, 0, 1))

	for _, x in ipairs({-0.9, 0.9}) do
		for _, z in ipairs({-0.8, 0.8}) do
			local world = start + rotation:VecMul(Vec3(x, -0.1, z))
			local went, wheel = spawn_wheel("car_wheel", world, 0.4)
			ents[#ents + 1] = went
			wheel_bodies[#wheel_bodies + 1] = wheel
			hinges[#hinges + 1] = HingeConstraint.New(car, wheel, world, axis)
		end
	end

	local max_error = 0
	local max_speed = 0
	local max_spin_ratio_error = 0
	local stack_hit = false

	for step = 1, 900 do
		physics.Update(1 / 120)

		for _, hinge in ipairs(hinges) do
			max_error = math.max(max_error, hinge:GetAnchorError())
		end

		max_speed = math.max(max_speed, car:GetVelocity():GetLength())

		if step == 240 then
			-- rolling without slipping on the ramp: |w| * r ~= |v|
			local spin = wheel_bodies[1]:GetAngularVelocity():GetLength() * 0.4
			local speed = wheel_bodies[1]:GetVelocity():GetLength()
			max_spin_ratio_error = math.abs(spin - speed) / math.max(speed, 0.001)
		end

		if stack[4]:GetPosition().y < 3 then stack_hit = true end
	end

	local top_position = stack[4]:GetPosition()
	local top_up = stack[4]:GetRotation():VecMul(Vec3(0, 1, 0))

	for _, hinge in ipairs(hinges) do
		hinge:Remove()
	end

	for _, ent in ipairs(ents) do
		ent:Remove()
	end

	T(max_error)["<"](0.02)
	T(max_speed)[">"](8)
	T(max_spin_ratio_error)["<"](0.25)
	T(stack_hit)["=="](true)
	T(top_position.y)["<"](2.6)
	T(math.abs(top_position.x - 7) > 0.7 or top_up.y < 0.9)["=="](true)
end)
