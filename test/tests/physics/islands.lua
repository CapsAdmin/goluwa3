local T = import("test/environment.lua")
local islands = import("goluwa/physics/islands.lua")

local function create_mock_body(name, motion_type)
	local owner = {
		IsValid = function()
			return true
		end,
		transform = {},
	}
	local body = {
		Name = name,
		Enabled = true,
		Owner = owner,
		MotionType = motion_type or "dynamic",
		Awake = motion_type ~= "dynamic",
		WakeCount = 0,
		SleepCount = 0,
		ReadyToSleep = false,
	}

	function body:IsDynamic()
		return self.MotionType == "dynamic"
	end

	function body:IsKinematic()
		return self.MotionType == "kinematic"
	end

	function body:IsStatic()
		return self.MotionType == "static"
	end

	function body:HasSolverMass()
		return self.MotionType == "dynamic"
	end

	function body:GetAwake()
		return self.Awake
	end

	function body:Wake()
		self.Awake = true
		self.WakeCount = self.WakeCount + 1
	end

	function body:Sleep()
		self.Awake = false
		self.SleepCount = self.SleepCount + 1
	end

	function body:IsReadyToSleep()
		return self.ReadyToSleep or not self.Awake
	end

	return body
end

local function create_pair(body_a, body_b)
	return {
		entry_a = {body = body_a},
		entry_b = {body = body_b},
	}
end

T.Test("Simulation islands do not merge dynamic bodies only linked through the same static anchor", function()
	local dynamic_a = create_mock_body("dynamic_a", "dynamic")
	local dynamic_b = create_mock_body("dynamic_b", "dynamic")
	local static_anchor = create_mock_body("static_anchor", "static")
	local built = islands.BuildSimulationIslands(
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
	T(#built[1].bodies)["=="](2)
	T(#built[2].bodies)["=="](2)
end)

T.Test("Simulation islands group constrained dynamic bodies and keep isolated bodies separate", function()
	local dynamic_a = create_mock_body("dynamic_a", "dynamic")
	local dynamic_b = create_mock_body("dynamic_b", "dynamic")
	local dynamic_c = create_mock_body("dynamic_c", "dynamic")
	local built = islands.BuildSimulationIslands(
		{dynamic_a, dynamic_b, dynamic_c},
		{},
		{
			{Body0 = dynamic_a, Body1 = dynamic_b, Enabled = true},
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
	local built = islands.BuildSimulationIslands(
		{dynamic_a, dynamic_b, kinematic_anchor},
		{
			create_pair(dynamic_a, kinematic_anchor),
			create_pair(dynamic_b, kinematic_anchor),
		},
		{}
	)
	T(#built)["=="](2)
	T(#built[1].bodies)["=="](2)
	T(#built[2].bodies)["=="](2)
	T(#built[1].dynamic_bodies)["=="](1)
	T(#built[2].dynamic_bodies)["=="](1)
end)

T.Test("Simulation islands cache dynamic bodies separately from anchors and constrained dynamics", function()
	local dynamic_a = create_mock_body("dynamic_a", "dynamic")
	local dynamic_b = create_mock_body("dynamic_b", "dynamic")
	local static_anchor = create_mock_body("static_anchor", "static")
	local built = islands.BuildSimulationIslands(
		{dynamic_a, dynamic_b, static_anchor},
		{
			create_pair(dynamic_a, static_anchor),
		},
		{
			{Body0 = dynamic_a, Body1 = dynamic_b, Enabled = true},
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
	local built = islands.BuildSimulationIslands({dynamic_a, dynamic_b}, {create_pair(dynamic_a, dynamic_b)}, {})
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
	local built = islands.BuildSimulationIslands(
		{dynamic_a, dynamic_b},
		{},
		{
			{Body0 = dynamic_a, Body1 = dynamic_b, Enabled = true},
		}
	)
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

T.Test("Simulation islands sleep constrained dynamics together when every body is ready", function()
	local dynamic_a = create_mock_body("dynamic_a", "dynamic")
	local dynamic_b = create_mock_body("dynamic_b", "dynamic")
	dynamic_a.Awake = true
	dynamic_b.Awake = true
	dynamic_a.ReadyToSleep = true
	dynamic_b.ReadyToSleep = true
	local built = islands.BuildSimulationIslands(
		{dynamic_a, dynamic_b},
		{},
		{
			{Body0 = dynamic_a, Body1 = dynamic_b, Enabled = true},
		}
	)
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
	local built = islands.BuildSimulationIslands(
		{dynamic_a, dynamic_b},
		{},
		{
			{Body0 = dynamic_a, Body1 = dynamic_b, Enabled = true},
		}
	)
	islands.PrepareSimulationIslands(built)
	local slept_any = islands.FinalizeSimulationIslands(built)
	T(slept_any)["=="](false)
	T(islands.IsSleepingIsland(built[1]))["=="](false)
	T(dynamic_a:GetAwake())["=="](true)
	T(dynamic_b:GetAwake())["=="](true)
	T(dynamic_a.SleepCount)["=="](0)
	T(dynamic_b.SleepCount)["=="](0)
end)

T.Test("Simulation islands do not force sleep single dynamic bodies constrained only to world anchors", function()
	local dynamic = create_mock_body("dynamic", "dynamic")
	dynamic.Awake = true
	dynamic.ReadyToSleep = true
	local built = islands.BuildSimulationIslands({dynamic}, {}, {
		{Body0 = nil, Body1 = dynamic, Enabled = true},
	})
	islands.PrepareSimulationIslands(built)
	local slept_any = islands.FinalizeSimulationIslands(built)
	T(slept_any)["=="](false)
	T(islands.IsSleepingIsland(built[1]))["=="](false)
	T(dynamic:GetAwake())["=="](true)
	T(dynamic.SleepCount)["=="](0)
end)