local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local sphere_shape = SphereShape.New

local function simulate_physics(steps, dt)
	return test_helpers.SimulatePhysics(physics, steps, dt)
end

local function reset_constraints()
	if physics.RemoveAllConstraints then physics.RemoveAllConstraints() end
end

local function create_dynamic_sphere(name, position, config)
	config = config or {}
	local ent = Entity.New({Name = name})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	local body = ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.25),
			Radius = 0.25,
			AutomaticMass = config.AutomaticMass == nil and false or config.AutomaticMass,
			Mass = config.Mass or 1,
			GravityScale = config.GravityScale or 0,
			LinearDamping = config.LinearDamping or 0,
			AngularDamping = config.AngularDamping or 0,
			AirLinearDamping = config.AirLinearDamping or 0,
			AirAngularDamping = config.AirAngularDamping or 0,
			MaxLinearSpeed = config.MaxLinearSpeed or 1000,
			MaxAngularSpeed = config.MaxAngularSpeed or 1000,
			SleepDelay = config.SleepDelay,
			SleepLinearThreshold = config.SleepLinearThreshold,
			SleepAngularThreshold = config.SleepAngularThreshold,
		}
	)
	return ent, body
end

T.Test3D("Distance constraint keeps two dynamic bodies linked", function()
	reset_constraints()
	local ent0, body0 = create_dynamic_sphere("constraint_link_body0", Vec3(-1, 2, 0))
	local ent1, body1 = create_dynamic_sphere("constraint_link_body1", Vec3(1, 2, 0))
	local constraint = physics.CreateDistanceConstraint(
		body0,
		body1,
		ent0.transform:GetPosition(),
		ent1.transform:GetPosition(),
		2,
		0,
		false
	)
	body0:ApplyImpulse(Vec3(10, 0, 0))
	simulate_physics(90, 1 / 120)
	local pos0 = ent0.transform:GetPosition():Copy()
	local pos1 = ent1.transform:GetPosition():Copy()
	local linked_distance = (pos1 - pos0):GetLength()
	local midpoint_x = (pos0.x + pos1.x) * 0.5
	local body1_velocity_x = body1:GetVelocity().x
	constraint:Destroy()
	ent0:Remove()
	ent1:Remove()
	reset_constraints()
	T(math.abs(linked_distance - 2))["<"](0.05)
	T(midpoint_x)[">"](0.2)
	T(body1_velocity_x)[">"](0.5)
end)

T.Test3D("Distance constraint supports world anchors", function()
	reset_constraints()
	local anchor = Vec3(0, 2, 0)
	local ent, body = create_dynamic_sphere("constraint_anchor_body", Vec3(3, 2, 0))
	local constraint = physics.CreateDistanceConstraint(nil, body, anchor, ent.transform:GetPosition(), 1, 0, false)
	simulate_physics(1, 1 / 60)
	local position = ent.transform:GetPosition():Copy()
	local anchored_distance = (position - anchor):GetLength()
	constraint:Destroy()
	ent:Remove()
	reset_constraints()
	T(math.abs(anchored_distance - 1))["<"](0.02)
	T(math.abs(position.x))[">"](0.95)
	T(math.abs(position.x))["<"](1.05)
	T(math.abs(position.y - 2))["<"](0.02)
end)

T.Test3D("Unilateral distance constraint behaves like a rope", function()
	reset_constraints()
	local anchor = Vec3(0, 0, 0)
	local ent, body = create_dynamic_sphere("constraint_rope_body", Vec3(1, 0, 0))
	local constraint = physics.CreateDistanceConstraint(nil, body, anchor, ent.transform:GetPosition(), 2, 0, true)
	simulate_physics(12, 1 / 120)
	local relaxed_distance = (ent.transform:GetPosition() - anchor):GetLength()
	ent.transform:SetPosition(Vec3(4, 0, 0))
	body:SynchronizeFromTransform()
	body:SetVelocity(Vec3(0, 0, 0))
	body:SetAngularVelocity(Vec3(0, 0, 0))
	simulate_physics(1, 1 / 60)
	local stretched_distance = (ent.transform:GetPosition() - anchor):GetLength()
	constraint:Destroy()
	ent:Remove()
	reset_constraints()
	T(math.abs(relaxed_distance - 1))["<"](0.02)
	T(math.abs(stretched_distance - 2))["<"](0.02)
end)