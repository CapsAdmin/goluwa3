local T = import("test/environment.lua")
local islands = import("goluwa/physics/islands.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local next_entry_id = 0

local function create_mock_body(name, motion_type)
	return test_helpers.CreateStubBody{
		Name = name,
		MotionType = motion_type or "dynamic",
		Awake = motion_type ~= "dynamic",
		ReadyToSleep = false,
	}
end

local function create_entry(body)
	next_entry_id = next_entry_id + 1
	return {id = next_entry_id, body = body}
end

local function create_pair(body_a, body_b)
	return {
		entry_a = create_entry(body_a),
		entry_b = create_entry(body_b),
	}
end

local function create_constraint(body_a, body_b)
	return {
		Body0 = body_a,
		Body1 = body_b,
		Enabled = true,
		IsValid = function(self)
			return true
		end,
	}
end

-- islands are persistent module state; every test starts from a clean slate
local function build_islands(bodies, candidate_pairs, constraints)
	islands.ResetState()
	return islands.UpdateSimulationIslands(bodies, candidate_pairs, constraints, nil)
end

T.Test("Simulation islands do not merge dynamic bodies only linked through the same static anchor", function()
	local dynamic_a = create_mock_body("dynamic_a", "dynamic")
	local dynamic_b = create_mock_body("dynamic_b", "dynamic")
	local static_anchor = create_mock_body("static_anchor", "static")
	local built = build_islands(
		{dynamic_a, dynamic_b, static_anchor},
		{
			create_pair(dynamic_a, static_anchor),
			create_pair(dynamic_b, static_anchor),
		},
		{}
	)
	T(#built)["=="](2)
	T(#built[1].pairs)["=="](1)
	T(#built[2].pairs)["=="](1)
	-- the anchor joins both islands but does not bridge the two dynamic islands
	T(#built[1].bodies + #built[2].bodies)["=="](4)
	T(#built[1].dynamic_bodies)["=="](1)
	T(#built[2].dynamic_bodies)["=="](1)
end)

T.Test("Simulation islands group constrained dynamic bodies and keep isolated bodies separate", function()
	local dynamic_a = create_mock_body("dynamic_a", "dynamic")
	local dynamic_b = create_mock_body("dynamic_b", "dynamic")
	local dynamic_c = create_mock_body("dynamic_c", "dynamic")
	local built = build_islands(
		{dynamic_a, dynamic_b, dynamic_c},
		{},
		{
			create_constraint(dynamic_a, dynamic_b),
		}
	)
	T(#built)["=="](2)
	local first_count = #built[1].bodies
	local second_count = #built[2].bodies
	T(
		(
				first_count == 2 and
				second_count == 1
			)
			or
			(
				first_count == 1 and
				second_count == 2
			)
	)["=="](true)
	T(
		(
				#built[1].constraints == 1 and
				#built[2].constraints == 0
			)
			or
			(
				#built[1].constraints == 0 and
				#built[2].constraints == 1
			)
	)["=="](true)
end)

T.Test("Simulation islands include kinematic anchors without traversing through them", function()
	local dynamic_a = create_mock_body("dynamic_a", "dynamic")
	local dynamic_b = create_mock_body("dynamic_b", "dynamic")
	local kinematic_anchor = create_mock_body("kinematic_anchor", "kinematic")
	local built = build_islands(
		{dynamic_a, dynamic_b, kinematic_anchor},
		{
			create_pair(dynamic_a, kinematic_anchor),
			create_pair(dynamic_b, kinematic_anchor),
		},
		{}
	)
	T(#built)["=="](2)
	T(#built[1].dynamic_bodies)["=="](1)
	T(#built[2].dynamic_bodies)["=="](1)
	-- each pair lives in the island of its dynamic body
	T(#built[1].pairs)["=="](1)
	T(#built[2].pairs)["=="](1)
	-- the anchor is a member of both islands
	T(#built[1].bodies + #built[2].bodies)["=="](4)
end)

T.Test("Simulation islands cache dynamic bodies separately from anchors and constrained dynamics", function()
	local dynamic_a = create_mock_body("dynamic_a", "dynamic")
	local dynamic_b = create_mock_body("dynamic_b", "dynamic")
	local static_anchor = create_mock_body("static_anchor", "static")
	local built = build_islands(
		{dynamic_a, dynamic_b, static_anchor},
		{
			create_pair(dynamic_a, static_anchor),
		},
		{
			create_constraint(dynamic_a, dynamic_b),
		}
	)
	T(#built)["=="](1)
	T(#built[1].bodies)["=="](3)
	T(#built[1].dynamic_bodies)["=="](2)
	T(#built[1].constraint_dynamic_bodies)["=="](2)
	T(built[1].has_constraints)["=="](true)
	T(built[1].dynamic_bodies[1] == static_anchor or
		built[1].dynamic_bodies[2] == static_anchor)["=="](false)
end)

T.Test("Simulation islands stay marked sleeping when all connected dynamics are asleep", function()
	local dynamic_a = create_mock_body("dynamic_a", "dynamic")
	local dynamic_b = create_mock_body("dynamic_b", "dynamic")
	dynamic_a.Awake = false
	dynamic_b.Awake = false
	local built = build_islands({dynamic_a, dynamic_b}, {create_pair(dynamic_a, dynamic_b)}, {})
	local woke_any = islands.PrepareSimulationIslands(built)
	T(woke_any)["=="](false)
	T(islands.IsSleepingIsland(built[1]))["=="](true)
	T(#(built[1].awake_dynamic_bodies or {}))["=="](0)
	T(dynamic_a.WakeCount)["=="](0)
	T(dynamic_b.WakeCount)["=="](0)
end)

T.Test("Simulation islands wake sleeping dynamics connected to an awake dynamic body", function()
	local dynamic_a = create_mock_body("dynamic_a", "dynamic")
	local dynamic_b = create_mock_body("dynamic_b", "dynamic")
	dynamic_a.Awake = true
	dynamic_b.Awake = false
	local built = build_islands({dynamic_a, dynamic_b}, {}, {
		create_constraint(dynamic_a, dynamic_b),
	})
	local woke_any, newly_awoken_bodies = islands.PrepareSimulationIslands(built)
	T(woke_any)["=="](true)
	T(islands.IsSleepingIsland(built[1]))["=="](false)
	T(#(built[1].awake_dynamic_bodies or {}))["=="](2)
	T(built[1].active_dynamic_count)["=="](2)
	T(dynamic_a.WakeCount)["=="](0)
	T(dynamic_b:GetAwake())["=="](true)
	T(dynamic_b.WakeCount)["=="](1)
	T(#newly_awoken_bodies)["=="](1)
	T(newly_awoken_bodies[1])["=="](dynamic_b)
end)

T.Test("Simulation islands merge when a new pair links two dynamic bodies", function()
	local dynamic_a = create_mock_body("dynamic_a", "dynamic")
	local dynamic_b = create_mock_body("dynamic_b", "dynamic")
	local built = build_islands({dynamic_a, dynamic_b}, {}, {})
	T(#built)["=="](2)
	-- a new candidate pair merges the two islands
	built = islands.UpdateSimulationIslands({dynamic_a, dynamic_b}, {create_pair(dynamic_a, dynamic_b)}, {}, nil)
	T(#built)["=="](1)
	T(#built[1].dynamic_bodies)["=="](2)
	T(#built[1].pairs)["=="](1)
end)

T.Test("Simulation islands split when the only link between dynamics is removed", function()
	local dynamic_a = create_mock_body("dynamic_a", "dynamic")
	local dynamic_b = create_mock_body("dynamic_b", "dynamic")
	local pair = create_pair(dynamic_a, dynamic_b)
	local built = build_islands({dynamic_a, dynamic_b}, {pair}, {})
	T(#built)["=="](1)
	T(#built[1].dynamic_bodies)["=="](2)
	-- the pair leaves the candidate set: the island splits back apart
	built = islands.UpdateSimulationIslands({dynamic_a, dynamic_b}, {}, {}, nil)
	T(#built)["=="](2)

	for i = 1, #built do
		T(#built[i].dynamic_bodies)["=="](1)
	end
end)

T.Test("Simulation islands keep links alive while pairs keep being candidates", function()
	local dynamic_a = create_mock_body("dynamic_a", "dynamic")
	local dynamic_b = create_mock_body("dynamic_b", "dynamic")
	local built = build_islands({dynamic_a, dynamic_b}, {create_pair(dynamic_a, dynamic_b)}, {})
	T(#built)["=="](1)
	-- fresh pair objects every update (broadphase recreates overflow pairs);
	-- the same link keeps the island merged
	built = islands.UpdateSimulationIslands({dynamic_a, dynamic_b}, {create_pair(dynamic_a, dynamic_b)}, {}, nil)
	T(#built)["=="](1)
	T(#built[1].pairs)["=="](1)
	built = islands.UpdateSimulationIslands({dynamic_a, dynamic_b}, {create_pair(dynamic_a, dynamic_b)}, {}, nil)
	T(#built)["=="](1)
	T(#built[1].pairs)["=="](1)
end)

T.Test("Simulation islands split when a constraint is removed", function()
	local dynamic_a = create_mock_body("dynamic_a", "dynamic")
	local dynamic_b = create_mock_body("dynamic_b", "dynamic")
	local constraint = create_constraint(dynamic_a, dynamic_b)
	local built = build_islands({dynamic_a, dynamic_b}, {}, {constraint})
	T(#built)["=="](1)
	-- removing the constraint splits the island
	built = islands.UpdateSimulationIslands({dynamic_a, dynamic_b}, {}, {}, nil)
	T(#built)["=="](2)
	-- re-adding the constraint merges it back
	built = islands.UpdateSimulationIslands({dynamic_a, dynamic_b}, {}, {constraint}, nil)
	T(#built)["=="](1)
	T(#built[1].constraints)["=="](1)
end)

T.Test("Simulation islands drop removed bodies and destroy empty islands", function()
	local dynamic_a = create_mock_body("dynamic_a", "dynamic")
	local dynamic_b = create_mock_body("dynamic_b", "dynamic")
	local built = build_islands({dynamic_a, dynamic_b}, {create_pair(dynamic_a, dynamic_b)}, {})
	T(#built)["=="](1)
	islands.RemoveBody(dynamic_b)
	T(#built)["=="](1)
	T(#built[1].dynamic_bodies)["=="](1)
	T(#built[1].bodies)["=="](1)
	-- removing the last dynamic body destroys the island
	islands.RemoveBody(dynamic_a)
	T(#built)["=="](0)
end)

T.Test("Simulation islands do not re-link removed bodies through live constraints", function()
	local dynamic_a = create_mock_body("dynamic_a", "dynamic")
	local dynamic_b = create_mock_body("dynamic_b", "dynamic")
	local constraint = create_constraint(dynamic_a, dynamic_b)
	local built = build_islands({dynamic_a, dynamic_b}, {}, {constraint})
	T(#built)["=="](1)
	T(#built[1].dynamic_bodies)["=="](2)
	-- the body is removed while its constraint stays alive; the next update
	-- must not pull the dead body back into an island
	dynamic_b.__removed = true
	islands.RemoveBody(dynamic_b)
	built = islands.UpdateSimulationIslands({dynamic_a}, {}, {constraint}, nil)
	T(#built)["=="](1)
	T(#built[1].dynamic_bodies)["=="](1)
	T(built[1].dynamic_bodies[1])["=="](dynamic_a)
	T(#built[1].constraints)["=="](0)
end)

T.Test("Simulation islands sleep constrained dynamics together when every body is ready", function()
	local dynamic_a = create_mock_body("dynamic_a", "dynamic")
	local dynamic_b = create_mock_body("dynamic_b", "dynamic")
	dynamic_a.Awake = true
	dynamic_b.Awake = true
	dynamic_a.ReadyToSleep = true
	dynamic_b.ReadyToSleep = true
	local built = build_islands({dynamic_a, dynamic_b}, {}, {
		create_constraint(dynamic_a, dynamic_b),
	})
	islands.PrepareSimulationIslands(built)
	local slept_any = islands.FinalizeSimulationIslands(built)
	T(slept_any)["=="](true)
	T(islands.IsSleepingIsland(built[1]))["=="](true)
	T(dynamic_a:GetAwake())["=="](false)
	T(dynamic_b:GetAwake())["=="](false)
	T(dynamic_a.SleepCount)["=="](1)
	T(dynamic_b.SleepCount)["=="](1)
	T(built[1].active_dynamic_count)["=="](0)
	T(#(built[1].awake_dynamic_bodies or {}))["=="](0)
end)

T.Test("Simulation islands keep constrained dynamics awake when one body is not sleep-ready", function()
	local dynamic_a = create_mock_body("dynamic_a", "dynamic")
	local dynamic_b = create_mock_body("dynamic_b", "dynamic")
	dynamic_a.Awake = true
	dynamic_b.Awake = true
	dynamic_a.ReadyToSleep = true
	dynamic_b.ReadyToSleep = false
	local built = build_islands({dynamic_a, dynamic_b}, {}, {
		create_constraint(dynamic_a, dynamic_b),
	})
	islands.PrepareSimulationIslands(built)
	local slept_any = islands.FinalizeSimulationIslands(built)
	T(slept_any)["=="](false)
	T(islands.IsSleepingIsland(built[1]))["=="](false)
	T(dynamic_a:GetAwake())["=="](true)
	T(dynamic_b:GetAwake())["=="](true)
	T(dynamic_a.SleepCount)["=="](0)
	T(dynamic_b.SleepCount)["=="](0)
end)

T.Test("Simulation islands wait for sleep delay before sleeping constrained dynamics", function()
	local dynamic_a = create_mock_body("dynamic_a", "dynamic")
	local dynamic_b = create_mock_body("dynamic_b", "dynamic")
	dynamic_a.Awake = true
	dynamic_b.Awake = true
	dynamic_a.ReadyToSleep = true
	dynamic_b.ReadyToSleep = true
	dynamic_a.SleepDelay = 0.5
	dynamic_b.SleepDelay = 0.5
	dynamic_a.SleepTimer = 0.2
	dynamic_b.SleepTimer = 0.2
	local built = build_islands({dynamic_a, dynamic_b}, {}, {
		create_constraint(dynamic_a, dynamic_b),
	})
	islands.PrepareSimulationIslands(built)
	local slept_any = islands.FinalizeSimulationIslands(built)
	T(slept_any)["=="](false)
	T(islands.IsSleepingIsland(built[1]))["=="](false)
	T(dynamic_a:GetAwake())["=="](true)
	T(dynamic_b:GetAwake())["=="](true)
	T(dynamic_a.SleepCount)["=="](0)
	T(dynamic_b.SleepCount)["=="](0)
	dynamic_a.SleepTimer = 0.5
	dynamic_b.SleepTimer = 0.5
	slept_any = islands.FinalizeSimulationIslands(built)
	T(slept_any)["=="](true)
	T(islands.IsSleepingIsland(built[1]))["=="](true)
	T(dynamic_a:GetAwake())["=="](false)
	T(dynamic_b:GetAwake())["=="](false)
	T(dynamic_a.SleepCount)["=="](1)
	T(dynamic_b.SleepCount)["=="](1)
end)

T.Test("Simulation islands do not force sleep single dynamic bodies constrained only to world anchors", function()
	local dynamic = create_mock_body("dynamic", "dynamic")
	dynamic.Awake = true
	dynamic.ReadyToSleep = true
	local built = build_islands({dynamic}, {}, {
		create_constraint(nil, dynamic),
	})
	islands.PrepareSimulationIslands(built)
	local slept_any = islands.FinalizeSimulationIslands(built)
	T(slept_any)["=="](false)
	T(islands.IsSleepingIsland(built[1]))["=="](false)
	T(dynamic:GetAwake())["=="](true)
	T(dynamic.SleepCount)["=="](0)
end)
