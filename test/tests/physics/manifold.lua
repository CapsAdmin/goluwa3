local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local manifold = import("goluwa/physics/manifold.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")

local function create_mock_body(data)
	data = data or {}

	if data.Friction == nil then data.Friction = 1 end

	return test_helpers.CreateStubBody(data)
end

T.Test("Manifold rebuild preserves tangent impulse state for matched contacts", function()
	local body_a = create_mock_body()
	local body_b = create_mock_body{Position = Vec3(0, 1, 0)}
	local data = {
		contacts = {
			{
				local_point_a = Vec3(0, 0, 0),
				local_point_b = Vec3(0, -1, 0),
				normal_impulse = 2.5,
				tangent_impulse = 0.75,
				tangent_impulse_2 = -0.25,
				tangent = Vec3(1, 0, 0),
			},
		},
	}
	local rebuilt = manifold.RebuildContacts(
		body_a,
		body_b,
		data,
		{
			{point_a = Vec3(0.02, 0, 0), point_b = Vec3(0.02, 0, 0)},
		}
	)
	T(#rebuilt)["=="](1)
	T(rebuilt[1].normal_impulse)["=="](2.5)
	T(rebuilt[1].tangent_impulse)["=="](0.75)
	T(rebuilt[1].tangent_impulse_1)["=="](0.75)
	T(rebuilt[1].tangent_impulse_2)["=="](-0.25)
	T(rebuilt[1].tangent.x)["=="](1)
	T(rebuilt[1].tangent.y)["=="](0)
	T(rebuilt[1].tangent.z)["=="](0)
end)

T.Test("Manifold warm start reapplies cached tangent impulses", function()
	local body_a = create_mock_body()
	local body_b = create_mock_body{Position = Vec3(0, 1, 0)}
	local data = {
		contacts = {
			{
				local_point_a = Vec3(),
				local_point_b = Vec3(0, -1, 0),
				normal_impulse = 0,
				tangent_impulse = 1,
				tangent_impulse_2 = 0.5,
				tangent = Vec3(1, 0, 0),
			},
		},
	}
	manifold.WarmStart(body_a, body_b, Vec3(0, 1, 0), data, 1 / 60)
	T(body_a:GetVelocity().x)["=="](-0.1)
	T(body_b:GetVelocity().x)["=="](0.1)
	T(math.abs(body_a:GetVelocity().z))[">"](0)
	T(math.abs(body_b:GetVelocity().z))[">"](0)
end)

T.Test("Manifold impulse solve accumulates tangent impulses across frames", function()
	local body_a = create_mock_body{Velocity = Vec3(1, 0, 1)}
	local body_b = create_mock_body{Position = Vec3(0, 1, 0)}
	local data = {
		contacts = {
			{
				local_point_a = Vec3(),
				local_point_b = Vec3(0, -1, 0),
				normal_impulse = 1,
				tangent_impulse = 0.2,
				tangent_impulse_2 = 0,
				tangent = Vec3(1, 0, 0),
			},
		},
	}
	local previous_impulse = data.contacts[1].tangent_impulse
	manifold.SolveImpulses(body_a, body_b, Vec3(0, 1, 0), data, 1 / 60)
	T(data.contacts[1].tangent ~= nil)["=="](true)
	T(math.abs(data.contacts[1].tangent_impulse))[">="](math.abs(previous_impulse))
	T(math.abs(data.contacts[1].tangent_impulse_2))[">"](0)
	T(body_a:GetVelocity().x)["<"](1)
	T(body_a:GetVelocity().z)["<"](1)
	T(math.abs(body_b:GetVelocity().x))[">"](0)
	T(math.abs(body_b:GetVelocity().z))[">"](0)
end)

T.Test("Manifold impulse solve uses static friction for low tangential speed", function()
	local body_a = create_mock_body{
		Velocity = Vec3(0.05, 0, 0),
		Friction = 0.01,
		StaticFriction = 0.2,
	}
	local body_b = create_mock_body{
		Position = Vec3(0, 1, 0),
		Friction = 0.01,
		StaticFriction = 0.2,
	}
	local data = {
		contacts = {
			{
				local_point_a = Vec3(),
				local_point_b = Vec3(0, -1, 0),
				normal_impulse = 1,
				tangent_impulse = 0,
				tangent_impulse_2 = 0,
				tangent = Vec3(1, 0, 0),
			},
		},
	}
	manifold.SolveImpulses(body_a, body_b, Vec3(0, 1, 0), data, 1 / 60)
	T(math.abs(body_a:GetVelocity().x))["<"](0.03)
	T(math.abs(data.contacts[1].tangent_impulse_1))[">"](0.01)
end)

T.Test("Manifold impulse solve falls back to dynamic friction above static threshold", function()
	local body_a = create_mock_body{
		Velocity = Vec3(1.0, 0, 0),
		Friction = 0.01,
		StaticFriction = 0.2,
	}
	local body_b = create_mock_body{
		Position = Vec3(0, 1, 0),
		Friction = 0.01,
		StaticFriction = 0.2,
	}
	local data = {
		contacts = {
			{
				local_point_a = Vec3(),
				local_point_b = Vec3(0, -1, 0),
				normal_impulse = 1,
				tangent_impulse = 0,
				tangent_impulse_2 = 0,
				tangent = Vec3(1, 0, 0),
			},
		},
	}
	manifold.SolveImpulses(body_a, body_b, Vec3(0, 1, 0), data, 1 / 60)
	T(math.abs(body_a:GetVelocity().x))[">"](0.9)
	T(math.abs(data.contacts[1].tangent_impulse_1))["<"](0.02)
end)

T.Test("Manifold static friction hysteresis keeps sticking slightly above enter threshold", function()
	local body_a = create_mock_body{
		Velocity = Vec3(0.1, 0, 0),
		Friction = 0.01,
		StaticFriction = 0.2,
	}
	local body_b = create_mock_body{
		Position = Vec3(0, 1, 0),
		Friction = 0.01,
		StaticFriction = 0.2,
	}
	local data = {
		contacts = {
			{
				local_point_a = Vec3(),
				local_point_b = Vec3(0, -1, 0),
				normal_impulse = 1,
				static_friction_active = true,
				tangent = Vec3(1, 0, 0),
			},
		},
	}
	manifold.SolveImpulses(body_a, body_b, Vec3(0, 1, 0), data, 1 / 60)
	T(data.contacts[1].static_friction_active)["=="](true)
	T(math.abs(body_a:GetVelocity().x))["<"](0.08)
end)

T.Test("Manifold solver uses extra passes only for slow resting multi-contact patches", function()
	local solver = physics.solver
	local old_base = solver.MANIFOLD_SOLVER_PASSES
	local old_resting = solver.RESTING_MANIFOLD_SOLVER_PASSES
	local old_min_contacts = solver.RESTING_MANIFOLD_MIN_CONTACTS
	local old_min_normal_y = solver.RESTING_MANIFOLD_MIN_NORMAL_Y
	local old_max_relative = solver.RESTING_MANIFOLD_MAX_RELATIVE_SPEED
	local old_max_tangent = solver.RESTING_MANIFOLD_MAX_TANGENT_SPEED
	local old_max_angular = solver.RESTING_MANIFOLD_MAX_ANGULAR_SPEED
	solver.MANIFOLD_SOLVER_PASSES = 1
	solver.RESTING_MANIFOLD_SOLVER_PASSES = 2
	solver.RESTING_MANIFOLD_MIN_CONTACTS = 3
	solver.RESTING_MANIFOLD_MIN_NORMAL_Y = 0.65
	solver.RESTING_MANIFOLD_MAX_RELATIVE_SPEED = 1.5
	solver.RESTING_MANIFOLD_MAX_TANGENT_SPEED = 0.75
	solver.RESTING_MANIFOLD_MAX_ANGULAR_SPEED = 2.5

	local body_a = create_mock_body{
		Velocity = Vec3(0.1, -0.02, 0.05),
		AngularVelocity = Vec3(0.05, 0, 0.1),
	}
	local fast_body_a = create_mock_body{
		Velocity = Vec3(3, 0, 0),
		AngularVelocity = Vec3(0.05, 0, 0.1),
	}
	local body_b = create_mock_body{
		Position = Vec3(0, 1, 0),
		Velocity = Vec3(),
		AngularVelocity = Vec3(),
		IsDynamic = false,
		InverseMass = 0,
	}
	local slow_contacts = {
		contacts = {
			{local_point_a = Vec3(-1, 0, -1), local_point_b = Vec3(-1, -1, -1)},
			{local_point_a = Vec3(1, 0, -1), local_point_b = Vec3(1, -1, -1)},
			{local_point_a = Vec3(0, 0, 1), local_point_b = Vec3(0, -1, 1)},
		},
	}
	local fast_contacts = {
		contacts = {
			{local_point_a = Vec3(-1, 0, 0), local_point_b = Vec3(-1, -1, 0)},
			{local_point_a = Vec3(1, 0, 0), local_point_b = Vec3(1, -1, 0)},
		},
	}
	local slow_passes = solver:GetManifoldSolverPasses(body_a, body_b, Vec3(0, 1, 0), slow_contacts)
	local fast_passes = solver:GetManifoldSolverPasses(fast_body_a, body_b, Vec3(0, 1, 0), fast_contacts)
	solver.MANIFOLD_SOLVER_PASSES = old_base
	solver.RESTING_MANIFOLD_SOLVER_PASSES = old_resting
	solver.RESTING_MANIFOLD_MIN_CONTACTS = old_min_contacts
	solver.RESTING_MANIFOLD_MIN_NORMAL_Y = old_min_normal_y
	solver.RESTING_MANIFOLD_MAX_RELATIVE_SPEED = old_max_relative
	solver.RESTING_MANIFOLD_MAX_TANGENT_SPEED = old_max_tangent
	solver.RESTING_MANIFOLD_MAX_ANGULAR_SPEED = old_max_angular
	T(slow_passes)["=="](2)
	T(fast_passes)["=="](1)
end)
