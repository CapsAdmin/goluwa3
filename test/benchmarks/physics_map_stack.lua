-- glw: --server
-- Loads a Source map, takes some of its dynamic props and stacks them above one location so they
-- fall onto each other, then reports step time and how the pile settles.
-- usage: luajit glw --server lua test/benchmarks/physics_map_stack.lua
-- env: STATS=1 prints the physics section summary, PROF=1 writes tmp/map_stack.glwp (both start at step DIAG_FROM). MAP, COUNT, MIN_RADIUS/MAX_RADIUS (prop size filter), SPACING (extra gap between bodies), X/Y/Z (stack base), STEPS, SETTLE, WINDOW
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local physics = import("goluwa/physics.lua")
local source_engine = import("goluwa/source_engine/source_engine.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local stats = import("goluwa/physics/stats.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local MAP = os.getenv("MAP") or "lostcoast"
local COUNT = tonumber(os.getenv("COUNT") or "10")
local SPACING = tonumber(os.getenv("SPACING") or "0.5")
local BASE = Vec3(
	tonumber(os.getenv("X") or "-75.447266"),
	tonumber(os.getenv("Y") or "51.144310"),
	tonumber(os.getenv("Z") or "-39.494789")
)
local MIN_RADIUS = tonumber(os.getenv("MIN_RADIUS") or "0.25")
local MAX_RADIUS = tonumber(os.getenv("MAX_RADIUS") or "1")
local SETTLE_STEPS = tonumber(os.getenv("SETTLE") or "120")
local MEASURE_STEPS = tonumber(os.getenv("STEPS") or "600")
local WINDOW_STEPS = tonumber(os.getenv("WINDOW") or "60")
local SLOW_STEP_MS = tonumber(os.getenv("SLOW_MS") or "300")
local DT = 1 / 60
local loaded_frames = 0
source_engine.Load(MAP)

local function step()
	physics.instance.Step(DT)
end

local function stats_of(bodies)
	local awake, max_speed, lowest = 0, 0, math.huge

	for _, body in ipairs(bodies) do
		if body:GetAwake() then awake = awake + 1 end

		max_speed = math.max(max_speed, body:GetVelocity():GetLength())
		lowest = math.min(lowest, body:GetPosition().y)
	end

	return awake, max_speed, lowest
end

local function run()
	local all_dynamic = {}

	for _, body in ipairs(RigidBody.Instances) do
		if body:IsDynamic() and body:HasSolverMass() then
			all_dynamic[#all_dynamic + 1] = body
		end
	end

	print(
		string.format(
			"map %s: %d dynamic bodies, %d bodies total",
			MAP,
			#all_dynamic,
			#RigidBody.Instances
		)
	)
	-- the engine's own physics update must not run on top of the manual stepping below
	event.RemoveListener("Update", "physics")
	local settle_start = system.GetTime()

	for _ = 1, SETTLE_STEPS do
		step()
	end

	print(
		string.format(
			"map settle: %.3f ms/step over %d steps, %d of %d awake afterwards",
			(system.GetTime() - settle_start) * 1000 / SETTLE_STEPS,
			SETTLE_STEPS,
			(stats_of(all_dynamic)),
			#all_dynamic
		)
	)
	-- crate/barrel sized props, in map order
	local stack = {}

	for _, body in ipairs(all_dynamic) do
		local half = body:GetHalfExtents()
		local radius = math.max(half.x, half.y, half.z)

		if radius >= MIN_RADIUS and radius <= MAX_RADIUS and #stack < COUNT then
			stack[#stack + 1] = body
		end
	end

	local height = BASE.y

	for i, body in ipairs(stack) do
		local half = body:GetHalfExtents()
		local radius = math.max(half.x, half.y, half.z)
		height = height + radius
		body.Owner.transform:SetPosition(Vec3(BASE.x, height, BASE.z))
		body:SetVelocity(Vec3(0, 0, 0))
		body:SetAngularVelocity(Vec3(0, 0, 0))
		body:Wake()
		height = height + radius + SPACING
		print(
			string.format(
				"  stack %2d: %s shape %s support points %d radius %.2f at y=%.2f",
				i,
				tostring(body.Owner.Name or "prop"),
				tostring(body:GetShapeType()),
				#(body:GetSupportLocalPoints() or {}),
				radius,
				height - radius - SPACING
			)
		)
	end

	local diagnostics_from = tonumber(os.getenv("DIAG_FROM") or "1")
	local times, sum, max = {}, 0, 0
	local window_sum, window_count = 0, 0
	local settled_at

	for i = 1, MEASURE_STEPS do
		if i == diagnostics_from then
			if os.getenv("STATS") then stats:Enable() end

			if os.getenv("PROF") then
				PROF.Start(
					"map_stack",
					{trace_recorder = false, shutdown = false, path = "tmp/map_stack.glwp"}
				)
			end
		end

		local t = system.GetTime()
		step()
		t = (system.GetTime() - t) * 1000
		times[i] = t

		if t > SLOW_STEP_MS then
			print(string.format("  slow step %d: %.1f ms", i, t))
		end

		sum = sum + t
		max = math.max(max, t)
		window_sum = window_sum + t
		window_count = window_count + 1

		if window_count == WINDOW_STEPS then
			local awake, max_speed, lowest = stats_of(stack)
			print(
				string.format(
					"steps %4d-%4d: %7.3f ms/step  stack awake %2d/%d  max speed %6.2f  lowest y %.2f",
					i - WINDOW_STEPS + 1,
					i,
					window_sum / window_count,
					awake,
					#stack,
					max_speed,
					lowest
				)
			)
			window_sum, window_count = 0, 0

			if awake == 0 and not settled_at then settled_at = i end
		end
	end

	if os.getenv("PROF") then PROF.Stop() end

	if os.getenv("STATS") then print(stats:Summary()) end

	table.sort(times)
	print(
		string.format(
			"total: mean %.3f ms  median %.3f  p95 %.3f  max %.3f over %d steps; stack %s",
			sum / MEASURE_STEPS,
			times[math.floor(MEASURE_STEPS / 2)],
			times[math.floor(MEASURE_STEPS * 0.95)],
			max,
			MEASURE_STEPS,
			settled_at and ("asleep after " .. settled_at .. " steps") or "still awake"
		)
	)
	system.ShutDown(0)
end

-- the map's collision body is built after the scene reports idle, so wait for it explicitly
local function has_world_body()
	for _, body in ipairs(RigidBody.Instances) do
		if body.Owner and body.Owner:HasComponent("bsp_world") then return true end
	end

	return false
end

event.AddListener("Update", "map_stack_benchmark", function()
	loaded_frames = loaded_frames + 1

	if loaded_frames > 5 and not scene_loading.IsLoading() and has_world_body() then
		event.RemoveListener("Update", "map_stack_benchmark")
		run()
	end
end)
