local event = import("goluwa/event.lua")
local physics_constants = import("goluwa/physics/constants.lua")
local islands = import("goluwa/physics/islands.lua")
local kinematic_controller = import("goluwa/physics/kinematic_controller.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local support_contacts = import("goluwa/physics/shapes/support_contacts.lua")
local stats = import("goluwa/physics/stats.lua")
local world_step = {}

-- support eligibility (dynamic, collision enabled, gravity scale) and the
-- owner/shape pairs are substep-invariant, so resolve them once per substep
-- instead of once per body per solver iteration
local function refresh_support_entries(bodies)
	for _, body in ipairs(bodies) do
		local entries = nil

		if body:IsDynamic() and body.CollisionEnabled and body:GetGravityScale() ~= 0 then
			local colliders = body:GetColliders()

			if #colliders == 1 then
				local shape = body:GetPhysicsShape()

				if shape then entries = {{body, shape}} end
			else
				for _, collider in ipairs(colliders) do
					local shape = collider:GetPhysicsShape()

					if shape then
						entries = entries or {}
						entries[#entries + 1] = {collider, shape}
					end
				end
			end
		end

		body._SupportEntries = entries
	end
end

local function solve_body_support_contacts(body, step_dt, substep_id)
	if not body:GetAwake() then return end

	local entries = body._SupportEntries

	if not entries then return end

	for i = 1, #entries do
		local entry = entries[i]
		support_contacts.SolveShapeSupportContacts(entry[1], entry[2], step_dt, substep_id)
	end
end

local function get_fixed_step(physics)
	return math.max(physics.FixedTimeStep, 0.000001)
end

function world_step.Step(physics, dt)
	if not dt or dt <= 0 then return end

	physics.StepIndex = (physics.StepIndex or 0) + 1
	physics.UpdateRigidBodies(dt)
end

function world_step.Update(physics, dt)
	if not dt or dt <= 0 then return 0 end

	physics.FrameAccumulator = 0
	physics.InterpolationAlpha = 0
	local fixed_dt = get_fixed_step(physics)
	local steps = 0

	while dt >= fixed_dt do
		physics.Step(fixed_dt)
		dt = dt - fixed_dt
		steps = steps + 1
	end

	if dt > 0 then
		physics.Step(dt)
		steps = steps + 1
	end

	return steps
end

function world_step.UpdateFixed(physics, dt)
	if not dt or dt <= 0 then return 0 end

	local max_frame_time = math.max(physics.MaxFrameTime or 0.1, 0)

	if max_frame_time > 0 then dt = math.min(dt, max_frame_time) end

	local fixed_dt = get_fixed_step(physics)
	local max_steps = math.max(1, physics.MaxStepsPerFrame or 8)
	local accumulator = (physics.FrameAccumulator or 0) + dt
	local steps = 0

	while steps < max_steps and accumulator >= fixed_dt do
		physics.Step(fixed_dt)
		accumulator = accumulator - fixed_dt
		steps = steps + 1
	end

	-- dropped the rest of the backlog to avoid spiralling into further steps
	if steps == max_steps then accumulator = 0 end

	physics.FrameAccumulator = accumulator
	physics.InterpolationAlpha = accumulator / fixed_dt
	return steps
end

function world_step.UpdateRigidBodies(physics, dt)
	if not dt or dt <= 0 then return end

	local bodies = RigidBody.Instances
	local solver = physics.solver

	if #bodies == 0 then return end

	local substeps = math.max(1, physics.RigidBodySubsteps or 1)
	local iterations = math.max(1, physics.RigidBodyIterations or 1)
	local sub_dt = dt / substeps
	local collision_pairs = physics.collision_pairs
	collision_pairs:BeginCollisionFrame()
	stats:Gauge("bodies", #bodies)
	stats:Gauge("substeps", substeps)
	stats:PushTime("step")
	stats:PushTime("synchronize")

	for _, body in ipairs(bodies) do
		body:SynchronizeFromTransform()
	end

	stats:PopTime()

	for _ = 1, substeps do
		if solver.BeginStep then solver:BeginStep() end

		stats:PushTime("integrate")
		local awake_count = 0

		for _, body in ipairs(bodies) do
			if body:IsKinematic() or body:HasKinematicController() then
				kinematic_controller.UpdateBody(body, sub_dt, physics.Gravity)
			elseif body:GetAwake() then
				awake_count = awake_count + 1
				body:ResetGroundSupport()
				body:SetGrounded(false)
				body:SetGroundNormal(physics_constants.UP)
				body:Integrate(sub_dt, physics.Gravity)
			else
				body.PreviousPosition = body.Position:Copy()
				body.PreviousRotation = body.Rotation:Copy()
			end
		end

		stats:Gauge("awake_bodies", awake_count)
		stats:PopTime()
		stats:PushTime("broadphase")
		local rigid_body_pairs = physics.broadphase:BuildCandidatePairs(bodies)
		stats:PopTime()
		local constraints = physics.GetConstraints()
		stats:PushTime("islands")
		local simulation_islands = islands.BuildSimulationIslands(bodies, rigid_body_pairs, constraints)
		local newly_awoken_bodies = {}

		if simulation_islands and simulation_islands[1] then
			local woke_any
			woke_any, newly_awoken_bodies = islands.PrepareSimulationIslands(simulation_islands, newly_awoken_bodies)

			if woke_any then
				for body_index = 1, #newly_awoken_bodies do
					local body = newly_awoken_bodies[body_index]

					if body:GetAwake() then
						body:ResetGroundSupport()
						body:SetGrounded(false)
						body:SetGroundNormal(physics_constants.UP)
						body:Integrate(sub_dt, physics.Gravity)
					end
				end

				stats:PopTime()
				stats:PushTime("broadphase")
				rigid_body_pairs = physics.broadphase:BuildCandidatePairs(bodies)
				stats:PopTime()
				stats:PushTime("islands")
				simulation_islands = islands.BuildSimulationIslands(bodies, rigid_body_pairs, constraints)

				if simulation_islands and simulation_islands[1] then
					islands.PrepareSimulationIslands(simulation_islands, newly_awoken_bodies)
				end
			end
		end

		stats:PopTime()
		stats:Gauge("candidate_pairs", #rigid_body_pairs)
		stats:Gauge("islands", simulation_islands and #simulation_islands or 0)
		-- CCD is resolved once per substep: its sweep window is the substep
		-- movement, so re-sweeping it after the first TOI rewind only paid the
		-- sweep cost against an already shrunken window
		stats:PushTime("ccd")

		for _, body in ipairs(bodies) do
			if body:IsDynamic() and body:GetAwake() then
				solver:SolveBodyContacts(body, sub_dt)
			end
		end

		stats:PopTime()
		refresh_support_entries(bodies)
		local substep_id = solver.StepStamp or 0

		for iter = 1, iterations do
			if simulation_islands and simulation_islands[1] then
				for island_index = 1, #simulation_islands do
					local island = simulation_islands[island_index]

					if not islands.IsSleepingIsland(island) then
						stats:PushTime("solve_pairs")
						solver:SolveRigidBodyPairs(island.pairs, sub_dt)
						stats:PopTime()
						stats:PushTime("support")
						local dynamic_bodies = island.awake_dynamic_bodies or island.dynamic_bodies or island.bodies

						for body_index = 1, #dynamic_bodies do
							solve_body_support_contacts(dynamic_bodies[body_index], sub_dt, substep_id)
						end

						stats:PopTime()
						stats:PushTime("constraints")
						solver:SolveDistanceConstraints(sub_dt, island.constraints)
						stats:PopTime()
					end
				end
			else
				stats:PushTime("solve_pairs")
				solver:SolveRigidBodyPairs(rigid_body_pairs, sub_dt)
				stats:PopTime()
				stats:PushTime("support")

				for _, body in ipairs(bodies) do
					if body:IsDynamic() and body:GetAwake() then
						solve_body_support_contacts(body, sub_dt, substep_id)
					end
				end

				stats:PopTime()
				stats:PushTime("constraints")
				solver:SolveDistanceConstraints(sub_dt, constraints)
				stats:PopTime()
			end
		end

		stats:PushTime("velocities_sleep")

		for _, body in ipairs(bodies) do
			body:UpdateVelocities(sub_dt)
			body:UpdateSleepState(sub_dt)
		end

		if simulation_islands and simulation_islands[1] then
			islands.FinalizeSimulationIslands(simulation_islands)
		end

		stats:PopTime()
	end

	stats:PushTime("finalize")

	for _, body in ipairs(bodies) do
		body:ClearAccumulators()
	end

	for _, body in ipairs(bodies) do
		body:WriteToTransform()
	end

	collision_pairs:DispatchCollisionEvents()
	stats:PopTime()
	stats:PopTime()
end

return world_step
