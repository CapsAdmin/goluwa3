local T = import("test/environment.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local manifold = import("goluwa/physics/manifold.lua")
local contact_solver = import("goluwa/physics/contact_solver.lua")
local contact_store = import("goluwa/physics/contact_store.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")

local function create_mock_body(data)
	data = data or {}

	if data.Friction == nil then data.Friction = 1 end

	if data.Awake == nil then data.Awake = true end

	if data.ShapeType == nil then data.ShapeType = "capsule" end

	return test_helpers.CreateStubBody(data)
end

local DT = 1 / 60

-- Builds a manifold the way manifold.RebuildContacts leaves it: persistent contacts in a ffi array.
local function create_manifold(contacts)
	local cs = contact_store.New(math.max(#contacts, 4))

	for i, source in ipairs(contacts) do
		local c = cs[i - 1]
		c.lax, c.lay, c.laz = source.local_a.x, source.local_a.y, source.local_a.z
		c.lbx, c.lby, c.lbz = source.local_b.x, source.local_b.y, source.local_b.z
		c.jn = source.normal_impulse or 0
		c.jt1 = source.tangent_impulse_1 or 0
		c.jt2 = source.tangent_impulse_2 or 0
		c.static_active = source.static_friction_active or 0
		c.rest_stamp = -1
		c.feature_key = -1
		c.has_sep = source.separation and 1 or 0
		c.sep = source.separation or 0

		if source.tangent then
			c.tx, c.ty, c.tz = source.tangent.x, source.tangent.y, source.tangent.z
			c.has_tangent = 1
		end
	end

	return {cs = cs, n = #contacts, normal = Vec3(0, 1, 0)}
end

-- Collects, prepares and warm starts one manifold, optionally followed by a solve sweep.
local function run_manifold(body_a, body_b, data, solve)
	local solver = body_a:GetPhysics().solver
	local friction = solver:GetPairFriction(body_a, body_b)
	local group = {}
	contact_solver.Begin(solver, DT)
	contact_solver.BeginGroup(group)
	contact_solver.Add(
		group,
		data,
		body_a,
		body_b,
		solver:GetPairRestitution(body_a, body_b),
		friction,
		math.max(friction, solver:GetPairStaticFriction(body_a, body_b)),
		manifold.SupportsPersistentTangent(body_a, body_b, data)
	)
	contact_solver.Prepare(solver, group, DT)

	if solve then contact_solver.Solve(group, false) end

	contact_solver.Store(group, DT)
end

-- Solve only: warm starting is disabled so the stored impulses are not applied first.
local function solve_impulses(body_a, body_b, data)
	local solver = body_a:GetPhysics().solver
	local warm, tangent_warm = solver.WARM_START_SCALE, solver.TANGENT_WARM_START_SCALE
	solver.WARM_START_SCALE, solver.TANGENT_WARM_START_SCALE = 0, 0
	run_manifold(body_a, body_b, data, true)
	solver.WARM_START_SCALE, solver.TANGENT_WARM_START_SCALE = warm, tangent_warm
end

T.TestPhysics("Manifold rebuild preserves tangent impulse state for matched contacts", function()
	local body_a = create_mock_body()
	local body_b = create_mock_body{Position = Vec3(0, 1, 0)}
	local data = create_manifold{
		{
			local_a = Vec3(0, 0, 0),
			local_b = Vec3(0, -1, 0),
			normal_impulse = 2.5,
			tangent_impulse_1 = 0.75,
			tangent_impulse_2 = -0.25,
			tangent = Vec3(1, 0, 0),
		},
	}
	manifold.RebuildContacts(
		body_a,
		body_b,
		data,
		{
			{point_a = Vec3(0.02, 0, 0), point_b = Vec3(0.02, 0, 0)},
		}
	)
	local rebuilt = data.cs[0]
	T(data.n)["=="](1)
	T(rebuilt.jn)["=="](2.5)
	T(rebuilt.jt1)["=="](0.75)
	T(rebuilt.jt2)["=="](-0.25)
	T(rebuilt.has_tangent)["=="](1)
	T(rebuilt.tx)["=="](1)
	T(rebuilt.ty)["=="](0)
	T(rebuilt.tz)["=="](0)
end)

T.TestPhysics("Manifold warm start reapplies cached tangent impulses", function()
	local body_a = create_mock_body()
	local body_b = create_mock_body{Position = Vec3(0, 1, 0)}
	local data = create_manifold{
		{
			local_a = Vec3(),
			local_b = Vec3(0, -1, 0),
			tangent_impulse_1 = 1,
			tangent_impulse_2 = 0.5,
			tangent = Vec3(1, 0, 0),
		},
	}
	run_manifold(body_a, body_b, data, false)
	T(body_a:GetVelocity().x)["~"](-0.1)
	T(body_b:GetVelocity().x)["~"](0.1)
	T(math.abs(body_a:GetVelocity().z))[">"](0)
	T(math.abs(body_b:GetVelocity().z))[">"](0)
end)

T.TestPhysics("Manifold impulse solve accumulates tangent impulses across frames", function()
	local body_a = create_mock_body{Velocity = Vec3(1, 0, 1)}
	local body_b = create_mock_body{Position = Vec3(0, 1, 0)}
	local data = create_manifold{
		{
			local_a = Vec3(),
			local_b = Vec3(0, -1, 0),
			normal_impulse = 1,
			tangent_impulse_1 = 0.2,
			tangent = Vec3(1, 0, 0),
		},
	}
	solve_impulses(body_a, body_b, data)
	T(data.cs[0].has_tangent)["=="](1)
	T(math.abs(data.cs[0].jt1))[">="](0.02)
	T(math.abs(data.cs[0].jt2))[">"](0)
	T(body_a:GetVelocity().x)["<"](1)
	T(body_a:GetVelocity().z)["<"](1)
	T(math.abs(body_b:GetVelocity().x))[">"](0)
	T(math.abs(body_b:GetVelocity().z))[">"](0)
end)

T.TestPhysics("Manifold impulse solve uses static friction for low tangential speed", function()
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
	local data = create_manifold{
		{
			local_a = Vec3(),
			local_b = Vec3(0, -1, 0),
			normal_impulse = 1,
			tangent = Vec3(1, 0, 0),
		},
	}
	solve_impulses(body_a, body_b, data)
	T(math.abs(body_a:GetVelocity().x))["<"](0.03)
	T(math.abs(data.cs[0].jt1))[">"](0.01)
end)

T.TestPhysics("Manifold impulse solve falls back to dynamic friction above static threshold", function()
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
	local data = create_manifold{
		{
			local_a = Vec3(),
			local_b = Vec3(0, -1, 0),
			normal_impulse = 1,
			tangent = Vec3(1, 0, 0),
		},
	}
	solve_impulses(body_a, body_b, data)
	T(math.abs(body_a:GetVelocity().x))[">"](0.9)
	T(math.abs(data.cs[0].jt1))["<"](0.02)
end)

T.TestPhysics("Manifold static friction hysteresis keeps sticking slightly above enter threshold", function()
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
	local data = create_manifold{
		{
			local_a = Vec3(),
			local_b = Vec3(0, -1, 0),
			normal_impulse = 1,
			static_friction_active = 1,
			tangent = Vec3(1, 0, 0),
		},
	}
	solve_impulses(body_a, body_b, data)
	T(data.cs[0].static_active)["=="](1)
	T(math.abs(body_a:GetVelocity().x))["<"](0.08)
end)

T.TestPhysics("Manifold solver uses extra passes only for slow resting multi-contact patches", function()
	local function first_impulse(velocity, contacts, resting_passes)
		local body_a = create_mock_body{Velocity = velocity, AngularVelocity = Vec3(0.05, 0, 0.1)}
		local body_b = create_mock_body{
			Position = Vec3(0, 1, 0),
			IsDynamic = false,
			InverseMass = 0,
		}
		body_a:GetPhysics().solver.RESTING_MANIFOLD_SOLVER_PASSES = resting_passes
		local list = {}

		for i, pair in ipairs(contacts) do
			list[i] = {local_a = pair[1], local_b = pair[2], separation = -0.01}
		end

		local data = create_manifold(list)
		solve_impulses(body_a, body_b, data)
		return data.cs[0].jn
	end

	local slow_patch = {
		{Vec3(-1, 0, -1), Vec3(-1, -1, -1)},
		{Vec3(1, 0, -1), Vec3(1, -1, -1)},
		{Vec3(0, 0, 1), Vec3(0, -1, 1)},
	}
	local fast_patch = {
		{Vec3(-1, 0, 0), Vec3(-1, -1, 0)},
		{Vec3(1, 0, 0), Vec3(1, -1, 0)},
		{Vec3(0, 0, 1), Vec3(0, -1, 1)},
	}
	local slow_single = first_impulse(Vec3(0.1, 0.5, 0.05), slow_patch, 1)
	local slow_resting = first_impulse(Vec3(0.1, 0.5, 0.05), slow_patch, 2)
	local fast_single = first_impulse(Vec3(3, 0.5, 0), fast_patch, 1)
	local fast_resting = first_impulse(Vec3(3, 0.5, 0), fast_patch, 2)
	T(slow_resting)["~="](slow_single)
	T(fast_resting)["=="](fast_single)
end)

T.TestPhysics("Manifold warm start does not push sleeping bodies", function()
	local body_a = create_mock_body{Awake = false}
	local body_b = create_mock_body{Position = Vec3(0, 1, 0)}
	local data = create_manifold{
		{
			local_a = Vec3(),
			local_b = Vec3(0, -1, 0),
			normal_impulse = 4,
		},
	}
	run_manifold(body_a, body_b, data, false)
	T(body_a:GetVelocity():GetLength())["=="](0)
	T(body_a:GetAwake())["=="](false)
	T(body_b:GetVelocity().y)[">"](0)
end)
