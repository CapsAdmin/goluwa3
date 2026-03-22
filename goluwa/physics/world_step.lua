local event = import("goluwa/event.lua")
local islands = import("goluwa/physics/islands.lua")
local kinematic_controller = import("goluwa/physics/kinematic_controller.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local support_contacts = import("goluwa/physics/shapes/support_contacts.lua")
local world_step = {}

local function solve_body_support_contacts(body, step_dt)
	if not (body:IsDynamic() and body:GetAwake() and body.CollisionEnabled) then
		return
	end

	if body:GetGravityScale() == 0 then return end

	local colliders = body:GetColliders()

	if #colliders == 1 then
		support_contacts.SolveShapeSupportContacts(body, body:GetPhysicsShape(), step_dt)
		return
	end

	for _, collider in ipairs(colliders) do
		support_contacts.SolveShapeSupportContacts(collider, collider:GetPhysicsShape(), step_dt)
	end
end

local function get_fixed_step(physics)
	return math.max(physics.FixedTimeStep, 0.000001)
end

function world_step.Step(physics, dt)
	if not dt or dt <= 0 then return end

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
	local accumulator = (physics.FrameAccumulator or 0) + dt
	local steps = 0

	while accumulator >= fixed_dt do
		physics.Step(fixed_dt)
		accumulator = accumulator - fixed_dt
		steps = steps + 1
	end

	if accumulator >= fixed_dt then accumulator = accumulator % fixed_dt end

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

	for _, body in ipairs(bodies) do
		body:SynchronizeFromTransform()
	end

	for _ = 1, substeps do
		if solver.BeginStep then solver:BeginStep() end

		for _, body in ipairs(bodies) do
			if body:IsKinematic() or body:HasKinematicController() then
				kinematic_controller.UpdateBody(body, sub_dt, physics.Gravity)
			elseif body:GetAwake() then
				body:ResetGroundSupport()
				body:SetGrounded(false)
				body:SetGroundNormal(physics.Up)
				body:Integrate(sub_dt, physics.Gravity)
			else
				body.PreviousPosition = body.Position:Copy()
				body.PreviousRotation = body.Rotation:Copy()
			end
		end

		local rigid_body_pairs = physics.broadphase:BuildCandidatePairs(bodies)
		local constraints = physics.GetConstraints()
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
						body:SetGroundNormal(physics.Up)
						body:Integrate(sub_dt, physics.Gravity)
					end
				end

				rigid_body_pairs = physics.broadphase:BuildCandidatePairs(bodies)
				simulation_islands = islands.BuildSimulationIslands(bodies, rigid_body_pairs, constraints)

				if simulation_islands and simulation_islands[1] then
					islands.PrepareSimulationIslands(simulation_islands, newly_awoken_bodies)
				end
			end
		end

		for _ = 1, iterations do
			if simulation_islands and simulation_islands[1] then
				for island_index = 1, #simulation_islands do
					local island = simulation_islands[island_index]

					if not islands.IsSleepingIsland(island) then
						solver:SolveRigidBodyPairs(island.pairs, sub_dt)
						local dynamic_bodies = island.awake_dynamic_bodies or island.dynamic_bodies or island.bodies

						for body_index = 1, #dynamic_bodies do
							local body = dynamic_bodies[body_index]
							solver:SolveBodyContacts(body, sub_dt)
							solve_body_support_contacts(body, sub_dt)
						end

						solver:SolveDistanceConstraints(sub_dt, island.constraints)
					end
				end
			else
				solver:SolveRigidBodyPairs(rigid_body_pairs, sub_dt)

				for _, body in ipairs(bodies) do
					if body:IsDynamic() and body:GetAwake() then
						solver:SolveBodyContacts(body, sub_dt)
						solve_body_support_contacts(body, sub_dt)
					end
				end

				solver:SolveDistanceConstraints(sub_dt, constraints)
			end
		end

		for _, body in ipairs(bodies) do
			body:UpdateVelocities(sub_dt)
			body:UpdateSleepState(sub_dt)
		end

		if simulation_islands and simulation_islands[1] then
			islands.FinalizeSimulationIslands(simulation_islands)
		end
	end

	for _, body in ipairs(bodies) do
		body:ClearAccumulators()
	end

	for _, body in ipairs(bodies) do
		body:WriteToTransform()
	end

	collision_pairs:DispatchCollisionEvents()
end

return world_step
