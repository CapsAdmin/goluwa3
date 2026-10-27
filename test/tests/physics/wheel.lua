local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local constraints = import("goluwa/physics/constraints.lua")
local HingeConstraint = import("goluwa/physics/constraints/hinge.lua")
local UP = Vec3(0, 1, 0)
local LEFT = Vec3(-1, 0, 0)
local RADIUS = 0.36
local MASS = 1200
local STIFFNESS = 40000

local function spawn(position, config)
	local ent = Entity.New({Name = "wheel_test"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	return ent:AddComponent("rigid_body", config)
end

local function spawn_ground()
	return spawn(
		Vec3(0, -0.5, 0),
		{Shape = BoxShape.New(Vec3(400, 1, 400)), MotionType = "static", Friction = 1}
	)
end

local function spawn_car()
	local car = spawn(
		Vec3(0, 0.62, 0),
		{
			Shape = BoxShape.New(Vec3(1.8, 0.4, 4.2)),
			Mass = MASS,
			AutomaticMass = false,
			Friction = 0.4,
		}
	)
	local wheels = {}

	for i, offset in ipairs{{-0.8, -1.35}, {0.8, -1.35}, {-0.8, 1.35}, {0.8, 1.35}} do
		local anchor = Vec3(offset[1], RADIUS - 0.08, offset[2])
		local body = spawn(
			anchor:Copy(),
			{
				Shape = SphereShape.New(RADIUS),
				Mass = 20,
				AutomaticMass = false,
				Friction = 1.1,
				MaxAngularSpeed = 400,
				SpinAxis = LEFT,
			}
		)
		wheels[i] = constraints.Wheel(
			car,
			body,
			anchor,
			UP,
			LEFT,
			{
				Stiffness = STIFFNESS,
				Damping = 3500,
				LowerTranslation = 0,
				UpperTranslation = 0.25,
			}
		)
	end

	return car, wheels
end

local function step(car, ticks)
	for _ = 1, ticks do
		car:Wake()
		physics.Update(1 / 60)
	end
end

local function heading(body)
	local forward = body:GetRotation():GetForward()
	return math.atan2(-forward.x, -forward.z)
end

T.TestPhysics("wheel joints hold a chassis at the sag of their springs", function()
	spawn_ground()
	local car, wheels = spawn_car()
	step(car, 120)
	local expected = MASS * 9.81 / 4 / STIFFNESS

	for _, wheel in ipairs(wheels) do
		T(math.abs(wheel:GetTranslation() - expected))["<"](0.01)
	end

	T(car:GetRotation():GetUp().y)[">"](0.999)
end)

T.TestPhysics("wheel joints drive the car with their motors and steer it with their axles", function()
	spawn_ground()
	local car, wheels = spawn_car()
	step(car, 60)

	for i = 3, 4 do
		wheels[i]:SetMotor(100, 1200)
	end

	step(car, 120)
	local speed = car:GetVelocity():Dot(car:GetRotation():GetForward())
	T(speed)[">"](8)
	T(math.abs(heading(car)))["<"](0.02)

	for i = 1, 4 do
		wheels[i]:SetMotor(0, 0)
		wheels[i]:SetSteerAngle(i <= 2 and -0.15 or 0)
	end

	step(car, 60)
	T(heading(car))["<"](-0.3)
	T(car:GetRotation():GetUp().y)[">"](0.95)
end)

local function spin_on_turning_body(make_joint)
	local chassis = spawn(
		Vec3(0, 10, 0),
		{
			Shape = SphereShape.New(0.7),
			Mass = 1000,
			AutomaticMass = false,
			GravityScale = 0,
		}
	)
	local anchor = Vec3(1.5, 10, 0)
	local wheel = spawn(
		anchor:Copy(),
		{
			Shape = SphereShape.New(RADIUS),
			Mass = 20,
			AutomaticMass = false,
			GravityScale = 0,
			MaxAngularSpeed = 5000,
		}
	)
	make_joint(chassis, wheel, anchor)
	chassis:SetAngularVelocity(Vec3(0, 2, 0))
	wheel:SetAngularVelocity(Vec3(50, 2, 0))
	local highest = 0

	for _ = 1, 120 do
		chassis:Wake()
		physics.Update(1 / 60)
		highest = math.max(highest, wheel:GetAngularVelocity():GetLength())
	end

	return highest
end

T.TestPhysics("a fast wheel on a turning chassis keeps its spin", function()
	local highest = spin_on_turning_body(function(chassis, wheel, anchor)
		constraints.Wheel(
			chassis,
			wheel,
			anchor,
			UP,
			Vec3(1, 0, 0),
			{Stiffness = STIFFNESS, Damping = 3000}
		)
	end)
	T(highest)["<"](55)
end)

T.TestPhysics("a fast hinge on a turning body keeps its spin", function()
	local highest = spin_on_turning_body(function(chassis, wheel, anchor)
		HingeConstraint.New(chassis, wheel, anchor, Vec3(1, 0, 0))
	end)
	T(highest)["<"](55)
end)

T.TestPhysics("keep upright with a roll axis rights the lean and leaves the pitch alone", function()
	local pitch = 0.4
	local rotation = Quat():Identity():RotatePitch(pitch):RotateRoll(0.5)
	local body = spawn(
		Vec3(0, 5, 0),
		{
			Shape = BoxShape.New(Vec3(0.4, 0.6, 1.4)),
			Mass = 200,
			AutomaticMass = false,
			GravityScale = 0,
		}
	)
	body.Owner.transform:SetRotation(rotation)
	body:SynchronizeFromTransform()
	constraints.KeepUpright(
		body,
		{LocalAxis = UP, LocalRollAxis = Vec3(0, 0, -1), Hertz = 3, DampingRatio = 1}
	)

	for _ = 1, 180 do
		body:Wake()
		physics.Update(1 / 60)
	end

	local forward = body:GetRotation():GetForward()
	local right = body:GetRotation():GetRight()
	T(math.abs(right.y))["<"](0.02)
	T(math.abs(math.asin(forward.y) - pitch))["<"](0.02)
end)
