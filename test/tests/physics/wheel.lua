local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local HingeConstraint = import("goluwa/physics/constraints/hinge.lua")
local RADIUS = 0.36

local function spawn(position, config)
	local ent = Entity.New({Name = "wheel_test"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	return ent:AddComponent("rigid_body", config)
end

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

T.TestPhysics("a fast hinge on a turning body keeps its spin", function()
	local highest = spin_on_turning_body(function(chassis, wheel, anchor)
		HingeConstraint.New(chassis, wheel, anchor, Vec3(1, 0, 0))
	end)
	T(highest)["<"](55)
end)
