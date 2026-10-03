local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local event = import("goluwa/event.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local constraints = import("goluwa/physics/constraints.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local DT = 1 / 120

local function gravity()
	return -physics.instance.Gravity.y
end

local function spawn_box(position, size, config)
	config = config or {}
	local ent = Entity.New({Name = "joint_test_box"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)

	if config.Rotation then ent.transform:SetRotation(config.Rotation) end

	return ent,
	ent:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(size),
			Size = size,
			Mass = config.Mass or 1,
			AutomaticMass = false,
			MotionType = config.MotionType,
			GravityScale = config.GravityScale,
			Friction = config.Friction or 0.5,
			LinearDamping = config.LinearDamping or 0,
			AngularDamping = config.AngularDamping or 0,
			AirLinearDamping = config.LinearDamping or 0,
			AirAngularDamping = config.AngularDamping or 0,
			MaxLinearSpeed = 1000,
			MaxAngularSpeed = 1000,
			CanSleep = config.CanSleep == true,
		}
	)
end

local function spawn_sphere(position, radius, config)
	config = config or {}
	local ent = Entity.New({Name = "joint_test_sphere"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	return ent,
	ent:AddComponent(
		"rigid_body",
		{
			Shape = SphereShape.New(radius),
			Radius = radius,
			Mass = config.Mass or 1,
			AutomaticMass = false,
			GravityScale = config.GravityScale,
			Friction = 0.5,
			LinearDamping = 0,
			AngularDamping = 0,
			AirLinearDamping = 0,
			AirAngularDamping = 0,
			MaxLinearSpeed = 1000,
			MaxAngularSpeed = 1000,
			CanSleep = false,
		}
	)
end

local function cleanup(...)
	physics.RemoveAllConstraints()

	for _, ent in ipairs({...}) do
		ent:Remove()
	end
end

local function inverse_inertia(body, x, y, z)
	local delta = body:GetAngularVelocityDelta(Vec3(x, y, z))
	return delta.x * x + delta.y * y + delta.z * z
end

T.TestPhysics("Weld holds a body to the world against gravity and knocks", function()
	physics.RemoveAllConstraints()
	local ent, body = spawn_box(Vec3(0, 5, 0), Vec3(1, 0.4, 0.6), {Mass = 3})
	local weld = constraints.Weld(nil, body, Vec3(0.5, 5, 0))
	body:ApplyImpulse(Vec3(4, 2, -3), Vec3(0.5, 5.2, 0.3))
	test_helpers.Simulate(360, DT)
	local position = ent.transform:GetPosition():Copy()
	local anchor_error = weld:GetAnchorError()
	local rotation_error = weld:GetRotationError()
	local reaction = weld:GetReactionForce()
	cleanup(ent)
	T(anchor_error)["<"](0.01)
	T(rotation_error)["<"](0.02)
	T(position:Distance(Vec3(0, 5, 0)))["<"](0.02)
	T(math.abs(reaction - 3 * gravity()) / (3 * gravity()))["<"](0.1)
end)

T.TestPhysics("Weld keeps two dynamic bodies in one rigid pose when struck", function()
	physics.RemoveAllConstraints()
	local ent_a, a = spawn_box(Vec3(0, 3, 0), Vec3(1, 1, 1), {Mass = 2, GravityScale = 0})
	local ent_b, b = spawn_box(Vec3(1.2, 3, 0), Vec3(1, 0.5, 0.5), {Mass = 1, GravityScale = 0})
	local weld = constraints.Weld(a, b, Vec3(0.6, 3, 0))
	local offset = (b.Position - a.Position):Copy()
	a:ApplyImpulse(Vec3(0, 3, 1), Vec3(0, 3.4, 0))
	b:ApplyImpulse(Vec3(-2, 0, 4), Vec3(1.7, 3, 0.2))
	test_helpers.Simulate(240, DT)
	local rotated = Quat.SetVecMul(Vec3(), a.Rotation, Vec3(offset.x, offset.y, offset.z))
	local relative = b.Position - a.Position
	local anchor_error = weld:GetAnchorError()
	local rotation_error = weld:GetRotationError()
	cleanup(ent_a, ent_b)
	T(anchor_error)["<"](0.02)
	T(rotation_error)["<"](0.05)
	T(relative:GetLength())["~"](offset:GetLength(), 0.03)
end)

T.TestPhysics("Ball socket swings like a pendulum and rotates freely", function()
	physics.RemoveAllConstraints()
	local ent, body = spawn_box(Vec3(2, 5, 0), Vec3(0.4, 0.4, 0.4), {Mass = 1})
	local socket = constraints.BallSocket(nil, body, Vec3(0, 5, 0))
	local lowest = math.huge
	local max_error = 0

	for _ = 1, 240 do
		test_helpers.Simulate(1, DT)
		lowest = math.min(lowest, ent.transform:GetPosition().y)
		max_error = math.max(max_error, socket:GetAnchorError())
	end

	cleanup(ent)
	T(max_error)["<"](0.01)
	T(lowest)["<"](3.2)
	local spin_ent, spinner = spawn_box(Vec3(0, 8, 0), Vec3(0.6, 0.4, 0.5), {Mass = 1})
	constraints.BallSocket(nil, spinner, Vec3(0, 8, 0))
	spinner:SetAngularVelocity(Vec3(0, 6, 0))
	test_helpers.Simulate(60, DT)
	local spin = spinner:GetAngularVelocity().y
	local drift = spin_ent.transform:GetPosition():Distance(Vec3(0, 8, 0))
	cleanup(spin_ent)
	T(spin)["~"](6, 0.3)
	T(drift)["<"](0.01)
end)

T.TestPhysics("Hinge limits stop a swinging bar at the limit angle", function()
	physics.RemoveAllConstraints()
	local ent, bar = spawn_box(Vec3(1, 5, 0), Vec3(2, 0.2, 0.2), {Mass = 2})
	local hinge = constraints.Hinge(nil, bar, Vec3(0, 5, 0), Vec3(0, 0, 1), {LowerAngle = -1.0, UpperAngle = 0.3})
	local lowest_angle = math.huge
	local highest_angle = -math.huge

	for _ = 1, 480 do
		test_helpers.Simulate(1, DT)
		local angle = hinge:GetAngle()
		lowest_angle = math.min(lowest_angle, angle)
		highest_angle = math.max(highest_angle, angle)
	end

	local final_angle = hinge:GetAngle()
	local speed = bar:GetAngularVelocity():GetLength()
	local anchor_error = hinge:GetAnchorError()
	cleanup(ent)
	T(lowest_angle)[">"](-1.06)
	T(highest_angle)["<"](0.33)
	T(final_angle)["~"](-1.0, 0.05)
	T(speed)["<"](0.5)
	T(anchor_error)["<"](0.02)
end)

T.TestPhysics("Hinge motor reaches its target speed within the torque limit", function()
	physics.RemoveAllConstraints()
	local ent, wheel = spawn_box(Vec3(0, 5, 0), Vec3(1, 1, 0.2), {Mass = 2, GravityScale = 0})
	local hinge = constraints.Motor(nil, wheel, Vec3(0, 5, 0), Vec3(0, 0, 1), 4, 100)
	test_helpers.Simulate(120, DT)
	local fast = wheel:GetAngularVelocity().z
	hinge:SetMotor(4, 0.5)
	hinge:SetMotor(-6, 0.5)
	local inverse = inverse_inertia(wheel, 0, 0, 1)
	local start = wheel:GetAngularVelocity().z
	test_helpers.Simulate(30, DT)
	local limited = wheel:GetAngularVelocity().z
	cleanup(ent)
	T(fast)["~"](4, 0.1)
	T(math.abs(limited - start))["~"](0.5 * 0.25 * inverse, 0.05 * math.max(1, 0.5 * 0.25 * inverse))
end)

T.TestPhysics("Hinge friction slows the rotation at a constant torque", function()
	physics.RemoveAllConstraints()
	local ent, wheel = spawn_box(Vec3(0, 5, 0), Vec3(1, 1, 0.2), {Mass = 2, GravityScale = 0})
	local friction = 0.4
	constraints.Hinge(nil, wheel, Vec3(0, 5, 0), Vec3(0, 0, 1), {Friction = friction})
	wheel:SetAngularVelocity(Vec3(0, 0, 3))
	local inverse = inverse_inertia(wheel, 0, 0, 1)
	test_helpers.Simulate(60, DT)
	local expected = 3 - friction * inverse * 0.5
	local speed = wheel:GetAngularVelocity().z
	cleanup(ent)
	T(speed)["~"](expected, 0.05)
end)

T.TestPhysics("Slider confines motion to its axis and stops at the limits", function()
	physics.RemoveAllConstraints()
	local ent, block = spawn_box(Vec3(0, 5, 0), Vec3(0.6, 0.6, 0.6), {Mass = 2})
	local slider = constraints.Slider(
		nil,
		block,
		Vec3(0, 5, 0),
		Vec3(1, 0, 0),
		{LowerTranslation = -1, UpperTranslation = 2}
	)
	block:SetVelocity(Vec3(6, 0, 3))
	block:ApplyImpulse(Vec3(0, 0, 1), Vec3(0, 5.2, 0))
	local highest = -math.huge

	for _ = 1, 240 do
		test_helpers.Simulate(1, DT)
		highest = math.max(highest, slider:GetTranslation())
	end

	local position = ent.transform:GetPosition():Copy()
	local rotation_error = slider:GetRotationError()
	cleanup(ent)
	T(math.abs(position.y - 5))["<"](0.02)
	T(math.abs(position.z))["<"](0.02)
	T(highest)["<"](2.06)
	T(highest)[">"](1.9)
	T(rotation_error)["<"](0.03)
end)

T.TestPhysics("Slider motor drives along the axis and friction resists", function()
	physics.RemoveAllConstraints()
	local ent, block = spawn_box(Vec3(0, 5, 0), Vec3(0.6, 0.6, 0.6), {Mass = 2, GravityScale = 0})
	local slider = constraints.Slider(nil, block, Vec3(0, 5, 0), Vec3(1, 0, 0), {MotorSpeed = 3, MaxMotorForce = 1000})
	test_helpers.Simulate(120, DT)
	local driven = block:GetVelocity().x
	slider:SetMotor(0, 0)
	slider:SetFriction(1)
	test_helpers.Simulate(30, DT)
	local slowed = block:GetVelocity().x
	cleanup(ent)
	T(driven)["~"](3, 0.1)
	T(slowed)["~"](3 - 0.5 * 0.25, 0.05)
end)

T.TestPhysics("Ragdoll joint limits twist and swing", function()
	physics.RemoveAllConstraints()
	local ent, arm = spawn_box(Vec3(0, 4, 0), Vec3(0.3, 2, 0.3), {Mass = 2})
	local joint = constraints.Ragdoll(
		nil,
		arm,
		Vec3(0, 5, 0),
		Vec3(0, -1, 0),
		{
			TwistMin = -0.5,
			TwistMax = 0.5,
			SwingYMin = -0.6,
			SwingYMax = 0.6,
			SwingZMin = -0.6,
			SwingZMax = 0.6,
		}
	)
	arm:SetAngularVelocity(Vec3(0, 12, 0))
	local max_twist = 0

	for _ = 1, 120 do
		test_helpers.Simulate(1, DT)
		local twist = joint:GetAngles()
		max_twist = math.max(max_twist, math.abs(twist))
	end

	arm:SetAngularVelocity(Vec3(9, 0, 0))
	local max_swing = 0

	for _ = 1, 120 do
		test_helpers.Simulate(1, DT)
		local _, swing_y, swing_z = joint:GetAngles()
		max_swing = math.max(max_swing, math.abs(swing_y), math.abs(swing_z))
	end

	local anchor_error = joint:GetAnchorError()
	cleanup(ent)
	T(max_twist)["<"](0.6)
	T(max_twist)[">"](0.4)
	T(max_swing)["<"](0.7)
	T(anchor_error)["<"](0.02)
end)

T.TestPhysics("Spring oscillates at the frequency of its stiffness", function()
	physics.RemoveAllConstraints()
	local mass, stiffness = 1, 100
	local ent, ball = spawn_sphere(Vec3(0.5, 5, 0), 0.2, {Mass = mass, GravityScale = 0})
	constraints.Spring(nil, ball, Vec3(0, 5, 0), Vec3(0.5, 5, 0), {Length = 0, Stiffness = stiffness})
	local previous = ent.transform:GetPosition().x
	local crossings = {}
	local time = 0

	for _ = 1, 480 do
		test_helpers.Simulate(1, DT)
		time = time + DT
		local x = ent.transform:GetPosition().x

		if previous > 0 and x <= 0 then crossings[#crossings + 1] = time end

		previous = x
	end

	cleanup(ent)
	local period = 2 * math.pi * math.sqrt(mass / stiffness)
	T(#crossings)[">="](3)
	T(crossings[2] - crossings[1])["~"](period, period * 0.04)
end)

T.TestPhysics("Damped spring settles at its rest length under gravity", function()
	physics.RemoveAllConstraints()
	local mass, stiffness = 1, 80
	local ent, ball = spawn_sphere(Vec3(0, 5, 0), 0.2, {Mass = mass})
	constraints.Spring(
		nil,
		ball,
		Vec3(0, 6, 0),
		Vec3(0, 5, 0),
		{Length = 1, Stiffness = stiffness, Damping = 6}
	)
	test_helpers.Simulate(480, DT)
	local y = ent.transform:GetPosition().y
	cleanup(ent)
	T(y)["~"](6 - 1 - mass * gravity() / stiffness, 0.02)
end)

T.TestPhysics("Rope pulls once taut and a slack rope is free", function()
	physics.RemoveAllConstraints()
	local ent, ball = spawn_sphere(Vec3(0, 5, 0), 0.2, {Mass = 1})
	local rope = constraints.Rope(nil, ball, Vec3(0, 6, 0), Vec3(0, 5, 0), {Length = 3})
	local slack_y = nil
	test_helpers.Simulate(20, DT)
	slack_y = ent.transform:GetPosition().y
	test_helpers.Simulate(360, DT)
	local taut_length = rope:GetCurrentLength()
	cleanup(ent)
	T(slack_y)["<"](4.99)
	T(taut_length)["~"](3, 0.03)
end)

T.TestPhysics("Hydraulic follows its target length at the set speed", function()
	physics.RemoveAllConstraints()
	local ent_a, a = spawn_box(Vec3(0, 5, 0), Vec3(0.4, 0.4, 0.4), {Mass = 2, GravityScale = 0})
	local ent_b, b = spawn_box(Vec3(2, 5, 0), Vec3(0.4, 0.4, 0.4), {Mass = 2, GravityScale = 0})
	local hydraulic = constraints.Hydraulic(a, b, Vec3(0, 5, 0), Vec3(2, 5, 0))
	hydraulic:SetTargetLength(4, 1)
	test_helpers.Simulate(120, DT)
	local halfway = hydraulic:GetCurrentLength()
	test_helpers.Simulate(360, DT)
	local final = hydraulic:GetCurrentLength()
	cleanup(ent_a, ent_b)
	T(halfway)["~"](3, 0.05)
	T(final)["~"](4, 0.03)
end)

T.TestPhysics("Muscle length follows its sine wave", function()
	physics.RemoveAllConstraints()
	local ent_a, a = spawn_box(Vec3(0, 5, 0), Vec3(0.4, 0.4, 0.4), {Mass = 2, GravityScale = 0})
	local ent_b, b = spawn_box(Vec3(2, 5, 0), Vec3(0.4, 0.4, 0.4), {Mass = 2, GravityScale = 0})
	local muscle = constraints.Muscle(a, b, Vec3(0, 5, 0), Vec3(2, 5, 0), 2, 0.5, 1)
	local lowest, highest = math.huge, -math.huge

	for _ = 1, 240 do
		test_helpers.Simulate(1, DT)
		local length = muscle:GetCurrentLength()
		lowest = math.min(lowest, length)
		highest = math.max(highest, length)
	end

	cleanup(ent_a, ent_b)
	T(lowest)["~"](1.5, 0.05)
	T(highest)["~"](2.5, 0.05)
end)

T.TestPhysics("Pulley moves two weights like an Atwood machine", function()
	physics.RemoveAllConstraints()
	local heavy, light = 2, 1
	local ent_a, a = spawn_sphere(Vec3(-1, 4, 0), 0.2, {Mass = heavy})
	local ent_b, b = spawn_sphere(Vec3(1, 4, 0), 0.2, {Mass = light})
	constraints.NoCollide(a, b)
	local pulley = constraints.Pulley(a, b, Vec3(-1, 8, 0), Vec3(1, 8, 0), Vec3(-1, 4, 0), Vec3(1, 4, 0))
	test_helpers.Simulate(60, DT)
	local drop = 4 - ent_a.transform:GetPosition().y
	local rise = ent_b.transform:GetPosition().y - 4
	local acceleration = (heavy - light) / (heavy + light) * gravity()
	local length_0, length_1 = pulley:GetLengths()
	cleanup(ent_a, ent_b)
	T(drop)["~"](0.5 * acceleration * 0.25, 0.03)
	T(rise)["~"](drop, 0.03)
	T(length_0 + length_1)["~"](8, 0.03)
end)

T.TestPhysics("Pulley with a ratio trades travel for tension", function()
	physics.RemoveAllConstraints()
	local ent_a, a = spawn_sphere(Vec3(-1, 4, 0), 0.2, {Mass = 4})
	local ent_b, b = spawn_sphere(Vec3(1, 4, 0), 0.2, {Mass = 1})
	constraints.NoCollide(a, b)
	local pulley = constraints.Pulley(
		a,
		b,
		Vec3(-1, 8, 0),
		Vec3(1, 8, 0),
		Vec3(-1, 4, 0),
		Vec3(1, 4, 0),
		{Ratio = 2}
	)
	test_helpers.Simulate(60, DT)
	local length_0, length_1 = pulley:GetLengths()
	local drop = 4 - ent_a.transform:GetPosition().y
	local rise = ent_b.transform:GetPosition().y - 4
	cleanup(ent_a, ent_b)
	local expected = 0.5 * (7 / 8.5) * gravity() * 0.25
	T(length_0 + 2 * length_1)["~"](12, 0.04)
	T(rise)["~"](drop / 2, 0.03)
	T(drop)["~"](expected, 0.05)
end)

T.TestPhysics("Keep upright rights a tilted body and leaves the spin free", function()
	physics.RemoveAllConstraints()
	local ent, body = spawn_box(
		Vec3(0, 5, 0),
		Vec3(0.6, 1.6, 0.6),
		{
			Mass = 2,
			GravityScale = 0,
			Rotation = Quat():SetAngles(Deg3(0, 0, 40)),
		}
	)
	body:SetAngularVelocity(Vec3(0, 5, 0))
	constraints.KeepUpright(body, {LocalAxis = Vec3(0, 1, 0)})
	test_helpers.Simulate(240, DT)
	local up = body:GetUp()
	local spin = body:GetAngularVelocity().y
	cleanup(ent)
	T(up.y)[">"](0.995)
	T(spin)["~"](5, 0.5)
end)

T.TestPhysics("A weld breaks above its force limit and holds below it", function()
	physics.RemoveAllConstraints()
	local broken = 0

	event.AddListener("PhysicsConstraintBroken", "joint_test_break", function()
		broken = broken + 1
	end)

	local ent_a, a = spawn_box(Vec3(0, 5, 0), Vec3(0.5, 0.5, 0.5), {Mass = 5})
	local ent_b, b = spawn_box(Vec3(3, 5, 0), Vec3(0.5, 0.5, 0.5), {Mass = 5})
	local strong = constraints.Weld(nil, a, Vec3(0, 5.25, 0), {BreakForce = 5 * gravity() * 4})
	local weak = constraints.Weld(nil, b, Vec3(3, 5.25, 0), {BreakForce = 5 * gravity() * 0.4})
	test_helpers.Simulate(240, DT)
	local a_y = ent_a.transform:GetPosition().y
	local b_y = ent_b.transform:GetPosition().y
	local weak_valid = weak:IsValid()
	local strong_valid = strong:IsValid()
	event.RemoveListener("PhysicsConstraintBroken", "joint_test_break")
	cleanup(ent_a, ent_b)
	T(strong_valid)["=="](true)
	T(weak_valid)["=="](false)
	T(broken)["=="](1)
	T(a_y)["~"](5, 0.05)
	T(b_y)["<"](3)
end)

T.TestPhysics("No collide lets two bodies pass through each other", function()
	physics.RemoveAllConstraints()
	local ground_ent, ground = spawn_box(Vec3(0, 0, 0), Vec3(10, 1, 10), {MotionType = "static"})
	local ent, box = spawn_box(Vec3(0, 3, 0), Vec3(1, 1, 1), {Mass = 1})
	constraints.NoCollide(ground, box)
	test_helpers.Simulate(240, DT)
	local y = ent.transform:GetPosition().y
	cleanup(ent, ground_ent)
	T(y)["<"](-1)
end)

T.TestPhysics("A hinge between two dynamic bodies limits the angle between them", function()
	physics.RemoveAllConstraints()
	local frame_ent, frame = spawn_box(Vec3(0, 5, 0), Vec3(0.3, 2, 0.3), {Mass = 20, GravityScale = 0})
	local door_ent, door = spawn_box(Vec3(0.8, 5, 0), Vec3(1.2, 1.8, 0.1), {Mass = 4, GravityScale = 0})
	local hinge = constraints.Hinge(
		frame,
		door,
		Vec3(0.2, 5, 0),
		Vec3(0, 1, 0),
		{LowerAngle = -0.2, UpperAngle = 1.2}
	)
	door:ApplyImpulse(Vec3(0, 0, -40), Vec3(1.2, 5, 0))
	local highest = -math.huge
	local lowest = math.huge

	for _ = 1, 240 do
		test_helpers.Simulate(1, DT)
		local angle = hinge:GetAngle()
		highest = math.max(highest, angle)
		lowest = math.min(lowest, angle)
	end

	local anchor_error = hinge:GetAnchorError()
	local axis_error = hinge:GetAxisError()
	cleanup(frame_ent, door_ent)
	T(highest)["<"](1.27)
	T(highest)[">"](1.0)
	T(lowest)[">"](-0.25)
	T(anchor_error)["<"](0.02)
	T(axis_error)["<"](0.03)
end)

T.TestPhysics("A hanging load on a chain of lighter links stays together", function()
	physics.RemoveAllConstraints()
	local ents = {}
	local joints = {}
	local previous = nil
	local last_body

	for i = 1, 12 do
		local ent, body = spawn_sphere(Vec3(0, 20 - i * 0.5, 0), 0.1, {Mass = i == 12 and 20 or 1})
		ents[i] = ent
		joints[i] = constraints.BallSocket(previous, body, Vec3(0, 20 - (i - 0.5) * 0.5, 0))
		previous = body
		last_body = body
	end

	test_helpers.Simulate(240, DT)
	local worst = 0

	for i = 1, 12 do
		worst = math.max(worst, joints[i]:GetAnchorError())
	end

	local end_y = ents[12].transform:GetPosition().y
	local top_force = joints[1]:GetReactionForce()
	cleanup(unpack(ents))
	T(worst)["<"](0.06)
	T(end_y)[">"](20 - 12 * 0.5 - 0.5)
	T(math.abs(top_force - (11 + 20) * gravity()) / ((11 + 20) * gravity()))["<"](0.1)
end)

T.TestPhysics("A spring between two bodies pulls both and keeps their center", function()
	physics.RemoveAllConstraints()
	local ent_a, a = spawn_sphere(Vec3(-2, 5, 0), 0.2, {Mass = 1, GravityScale = 0})
	local ent_b, b = spawn_sphere(Vec3(2, 5, 0), 0.2, {Mass = 3, GravityScale = 0})
	constraints.Spring(a, b, Vec3(-2, 5, 0), Vec3(2, 5, 0), {Length = 1, Stiffness = 60, Damping = 4})
	test_helpers.Simulate(60, DT)
	local mid = (a.Position * 1 + b.Position * 3) / 4
	test_helpers.Simulate(420, DT)
	local length = (b.Position - a.Position):GetLength()
	local center = (a.Position * 1 + b.Position * 3) / 4
	cleanup(ent_a, ent_b)
	T(length)["~"](1, 0.02)
	T(center:Distance(Vec3(1, 5, 0)))["<"](0.01)
end)

T.TestPhysics("A joint holds a body to a moving kinematic body", function()
	physics.RemoveAllConstraints()
	local platform_ent, platform = spawn_box(Vec3(0, 5, 0), Vec3(1, 0.4, 1), {MotionType = "kinematic"})
	local ent, body = spawn_box(Vec3(0, 4, 0), Vec3(0.5, 0.5, 0.5), {Mass = 2})
	local rope = constraints.Rod(platform, body, Vec3(0, 5, 0), Vec3(0, 4, 0), {Length = 1})

	for step = 1, 240 do
		platform_ent.transform:SetPosition(Vec3(step * DT * 2, 5, 0))
		test_helpers.Simulate(1, DT)
	end

	local gap = (ent.transform:GetPosition() - platform_ent.transform:GetPosition()):GetLength()
	local x = ent.transform:GetPosition().x
	cleanup(platform_ent, ent)
	T(gap)["~"](1, 0.05)
	T(x)[">"](2.5)
end)

T.TestPhysics("A world anchored joint keeps holding after its island splits", function()
	physics.RemoveAllConstraints()
	local ground_ent = spawn_box(Vec3(0, -0.5, 0), Vec3(30, 1, 30), {MotionType = "static"})
	local bob_ent, bob = spawn_sphere(Vec3(0, 0.6, 0), 0.5, {Mass = 4})
	local rod = constraints.Rod(nil, bob, Vec3(0, 3, 0), Vec3(0, 0.6, 0), {Length = 2.4})
	local roller_ent, roller = spawn_sphere(Vec3(-4, 0.4, 0.86), 0.4, {Mass = 2})
	roller:SetVelocity(Vec3(5, 0, 0))
	test_helpers.Simulate(360, DT)
	local stretch = bob.Position:Distance(Vec3(0, 3, 0))
	local roller_x = roller.Position.x
	cleanup(bob_ent, roller_ent, ground_ent)
	T(roller_x)[">"](2)
	T(stretch)["~"](2.4, 0.1)
end)

T.TestPhysics("A weight on a hinged plank tips it to the limit and stays on it", function()
	physics.RemoveAllConstraints()
	local _, pivot = spawn_box(Vec3(0, 0.65, 0), Vec3(0.4, 1.3, 0.4), {MotionType = "static"})
	local plank_ent, plank = spawn_box(
		Vec3(0, 1.45, 0),
		Vec3(5, 0.2, 1.2),
		{
			Mass = 6,
			CanSleep = true,
			Friction = 0.7,
			LinearDamping = 0.02,
			AngularDamping = 0.05,
		}
	)
	local hinge = constraints.Hinge(
		pivot,
		plank,
		Vec3(0, 1.45, 0),
		Vec3(0, 0, 1),
		{LowerAngle = -0.3, UpperAngle = 0.3}
	)
	local weight_ent, weight = spawn_box(
		Vec3(-2, 1.85, 0),
		Vec3(0.6, 0.6, 0.6),
		{Mass = 3, CanSleep = true, Friction = 0.7}
	)
	local seated = true

	for _ = 1, 120 do
		test_helpers.Simulate(1, 1 / 60)
		seated = seated and plank:WorldToLocal(weight.Position).y > 0.3
	end

	local angle = hinge:GetAngle()
	local speed = plank:GetAngularVelocity():GetLength()
	cleanup(plank_ent, weight_ent, pivot.Owner)
	T(angle)["~"](0.3, 0.005)
	T(speed)["<"](0.1)
	T(seated)["=="](true)
end)

T.TestPhysics("A removed joint leaves its island even after the object is cleared", function()
	physics.RemoveAllConstraints()
	local ent_a, a = spawn_box(Vec3(0, 3, 0), Vec3(0.8, 0.8, 0.8), {Mass = 2})
	local ent_b, b = spawn_box(Vec3(0.8, 3, 0), Vec3(0.8, 0.8, 0.8), {Mass = 2})
	local rod_a = constraints.Rod(nil, a, Vec3(0, 5, 0), Vec3(0, 3.4, 0))
	local rod_b = constraints.Rod(nil, b, Vec3(0.8, 5, 0), Vec3(0.8, 3.4, 0))
	test_helpers.Simulate(30, 1 / 60)
	rod_a:Remove()
	import("goluwa/objects/objects.lua").CheckRemovedObjects()
	test_helpers.Simulate(60, 1 / 60)
	local intact = rod_b:IsValid()
	local hanging = b.Position.y > 2
	cleanup(ent_a, ent_b)
	T(intact)["=="](true)
	T(hanging)["=="](true)
end)
